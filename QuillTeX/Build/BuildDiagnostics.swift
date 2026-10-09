import Foundation

/// One problem reported by the typesetting run.
struct BuildDiagnostic: Identifiable, Hashable {
    enum Severity: String {
        case error, warning, info
        var title: String {
            switch self {
            case .error: "Error"
            case .warning: "Warning"
            case .info: "Info"
            }
        }
    }
    let id = UUID()
    var severity: Severity
    var message: String
    /// Absolute location in the project, when the log named one.
    var file: URL?
    var line: Int?
    /// The log lines this came from, kept for the detail pane.
    var detail: String = ""

    var location: String {
        guard let file else { return "" }
        let name = file.lastPathComponent
        if let line { return "\(name):\(line)" }
        return name
    }
    var summary: String { message.isEmpty ? severity.title : message }

    static func == (lhs: BuildDiagnostic, rhs: BuildDiagnostic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Turns a LaTeX/latexmk transcript into diagnostics. Pure string work so it can be
/// tested against captured logs without running TeX.
enum BuildLogParser {
    /// `path:line: message` and `path:line:column: message` — the shape produced by
    /// `-file-line-error`, which is why the app always passes that flag.
    private static let fileLine = try? NSRegularExpression(pattern: #"^(.+?):(\d+):(?:\s*(\d+):)?\s*(.*)$"#)
    /// A file being opened, as LaTeX writes it: `(./chapters/intro.tex` or `(/abs/x.sty`.
    private static let openFile = try? NSRegularExpression(pattern: #"\((\.[^()\s]*|/[^()\s]*)"#)
    /// `l.42` marks the line of the error that follows a `!` message.
    private static let lineMark = try? NSRegularExpression(pattern: #"^l\.(\d+)\s"#)
    /// `on input line 42` in warnings.
    private static let inputLine = try? NSRegularExpression(pattern: #"on input line (\d+)"#)

    static func diagnostics(in log: String, workingDirectory: URL) -> [BuildDiagnostic] {
        var result: [BuildDiagnostic] = []
        var openStack: [URL] = []
        var pendingError: BuildDiagnostic?

        func resolve(_ raw: String) -> URL? {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let url = trimmed.hasPrefix("/")
                ? URL(fileURLWithPath: trimmed)
                : URL(fileURLWithPath: trimmed, relativeTo: workingDirectory)
            let standardized = url.standardizedFileURL
            let ext = standardized.pathExtension.lowercased()
            return ["tex", "sty", "cls", "ltx", "def", "cfg", "bib"].contains(ext) ? standardized : nil
        }

        func matches(_ regex: NSRegularExpression?, _ text: String) -> [NSTextCheckingResult] {
            guard let regex else { return [] }
            return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        }
        func group(_ result: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
            let range = result.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: range)
        }

        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            // Bookkeeping first: LaTeX opens and closes files all over the transcript,
            // and that stack is what gives a bare `!` error its file.
            for match in matches(openFile, line) {
                if let raw = group(match, 1, in: line), let url = resolve(raw) {
                    openStack.append(url)
                    if raw.hasSuffix(".tex") { break }
                }
            }
            let closers = line.filter { $0 == ")" }.count
            if closers > 0, !openStack.isEmpty { openStack.removeLast(min(closers, openStack.count)) }

            // An error block: remember it, then fill in the file/line from `l.NN`.
            if let pending = pendingError {
                if let match = matches(lineMark, line).first, let number = group(match, 1, in: line) {
                    var filled = pending
                    filled.line = Int(number)
                    if filled.file == nil { filled.file = openStack.last }
                    filled.detail = (filled.detail + "\n" + line).trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(filled)
                    pendingError = nil
                    continue
                }
                if line.hasPrefix("!") || line.isEmpty {
                    result.append(pending); pendingError = nil
                } else {
                    pendingError?.detail += "\n" + line
                    if pendingError?.message.isEmpty == true { pendingError?.message = line }
                    continue
                }
            }
            if line.hasPrefix("!") {
                var diagnostic = BuildDiagnostic(severity: .error,
                                                 message: line.dropFirst().trimmingCharacters(in: .whitespaces),
                                                 file: openStack.last, line: nil, detail: line)
                if let match = matches(inputLine, line).first, let number = group(match, 1, in: line) { diagnostic.line = Int(number) }
                pendingError = diagnostic
                continue
            }

            // `file:line: message` is the most precise form; prefer it.
            if let match = matches(fileLine, line).first,
               let path = group(match, 1, in: line),
               let number = group(match, 2, in: line).flatMap(Int.init),
               let url = resolve(path) {
                let message = (group(match, 4, in: line) ?? "").trimmingCharacters(in: .whitespaces)
                let severity: BuildDiagnostic.Severity = message.localizedCaseInsensitiveContains("warning") ? .warning : .error
                result.append(BuildDiagnostic(severity: severity, message: message, file: url, line: number, detail: line))
                continue
            }

            // Warnings without a file: keep the line number when the log gives one.
            if line.contains("Warning") {
                let message = line.trimmingCharacters(in: .whitespaces)
                guard !message.hasPrefix("(Font)") else { continue }
                // Using a template by absolute path always produces this one, and it says
                // nothing the writer can act on: "you have requested package X but the
                // package provides Y". Filtered out rather than shown on every build.
                guard !message.contains("You have requested package") else { continue }
                var diagnostic = BuildDiagnostic(severity: .warning, message: message, file: openStack.last, line: nil, detail: message)
                if let match = matches(inputLine, line).first, let number = group(match, 1, in: line) { diagnostic.line = Int(number) }
                result.append(diagnostic)
            }
        }
        if let pending = pendingError { result.append(pending) }

        // The same problem is often reported twice (latexmk summary + raw TeX log).
        result.removeAll { $0.message.contains("You have requested package") || $0.message.hasPrefix("but the package provides") }
        var seen = Set<String>()
        return result.filter { diagnostic in
            let key = "\(diagnostic.severity.rawValue)|\(diagnostic.file?.path ?? "")|\(diagnostic.line ?? -1)|\(diagnostic.message)"
            return seen.insert(key).inserted
        }
    }

    /// A one-line verdict for the status area.
    static func summary(for diagnostics: [BuildDiagnostic], succeeded: Bool) -> String {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.filter { $0.severity == .warning }.count
        if succeeded && errors == 0 {
            return warnings == 0 ? "Build succeeded" : "Build succeeded · \(warnings) warning\(warnings == 1 ? "" : "s")"
        }
        if errors == 0 { return "Build failed" }
        return "\(errors) error\(errors == 1 ? "" : "s")" + (warnings > 0 ? " · \(warnings) warning\(warnings == 1 ? "" : "s")" : "")
    }
}
