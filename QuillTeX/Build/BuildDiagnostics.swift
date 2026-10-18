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
    enum Category: String, CaseIterable, Identifiable {
        case compilation, layout, references, bibliography
        var id: String { rawValue }
        var title: String {
            switch self {
            case .compilation: "Compilation"
            case .layout: "Layout"
            case .references: "References"
            case .bibliography: "Bibliography"
            }
        }
        var isProofreading: Bool { self == .layout || self == .references }
    }
    let id = UUID()
    var severity: Severity
    var message: String
    /// Absolute location in the project, when the log named one.
    var file: URL?
    var line: Int?
    /// The log lines this came from, kept for the detail pane.
    var detail: String = ""
    var category: Category = .compilation
    var endLine: Int?
    /// The reference, citation or label named by the warning, when available.
    var relatedKey: String?

    /// A brief next step; the original message and transcript remain available.
    var guidance: String? {
        let text = message.lowercased()
        if text.contains("undefined control sequence") { return "Check the command spelling and the package that defines it." }
        if text.contains("missing $ inserted") { return "Check that math symbols are inside a math environment." }
        if text.contains("runaway argument") || text.contains("file ended while scanning") { return "Check for an unclosed brace or environment before this line." }
        if text.contains("ended by") || text.contains("missing \\end") { return "Match each \\begin with the corresponding \\end." }
        if text.contains("not found") || text.contains("can't find") || text.contains("couldn't open") {
            return category == .bibliography ? "Check the bibliography filename and its path in the project." : "Check the filename, its path, and whether the required package is installed."
        }
        if text.hasPrefix("overfull") { return "Check for text or formulas extending past the page margin." }
        if text.hasPrefix("underfull") { return "Check spacing and line breaks in this paragraph." }
        if text.contains("multiply defined") || text.contains("multiply-defined") { return "Give each \\label a unique name, then compile again." }
        if category == .references {
            return text.contains("citation") || text.contains("database entry") ? "Check the citation key, bibliography file and selected bibliography strategy." : "Check the label spelling, then compile until references resolve."
        }
        if category == .bibliography, severity == .error { return "Check the bibliography entry syntax and the selected BibTeX or Biber step." }
        return nil
    }

    var location: String {
        guard let file else { return "" }
        let name = file.lastPathComponent
        if let line {
            if let endLine, endLine > line { return "\(name):\(line)–\(endLine)" }
            return "\(name):\(line)"
        }
        return name
    }
    var summary: String { message.isEmpty ? severity.title : message }

    static func == (lhs: BuildDiagnostic, rhs: BuildDiagnostic) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Shared by the result list and problem navigation, so hidden problems cannot
/// unexpectedly become the next selected row.
struct BuildDiagnosticFilter: Equatable {
    enum Severity: String, CaseIterable, Identifiable {
        case all, errors, warnings
        var id: String { rawValue }
        var title: String {
            switch self { case .all: "All severities"; case .errors: "Errors"; case .warnings: "Warnings" }
        }
    }
    var severity: Severity = .all
    var category: BuildDiagnostic.Category?

    func includes(_ diagnostic: BuildDiagnostic) -> Bool {
        if let category, diagnostic.category != category { return false }
        switch severity {
        case .all: return true
        case .errors: return diagnostic.severity == .error
        case .warnings: return diagnostic.severity == .warning
        }
    }
}

/// Turns a LaTeX/latexmk transcript into diagnostics. Pure string work so it can be
/// tested against captured logs without running TeX.
enum BuildLogParser {
    /// `path:line: message` and `path:line:column: message` — the shape produced by
    /// `-file-line-error`, which is why the app always passes that flag.
    private static let fileLine = try? NSRegularExpression(pattern: #"^(.+?):(\d+):(?:\s*(\d+):)?\s*(.*)$"#)
    /// A file being opened, as LaTeX writes it: `(./chapters/intro.tex` or `(/abs/x.sty`.
    private static let openFile = try? NSRegularExpression(pattern: #"\(((?:\./|/)[^()\n]*?\.(?:tex|sty|cls|ltx|def|cfg|bib))(?=[\s()]|$)"#)
    /// `l.42` marks the line of the error that follows a `!` message.
    private static let lineMark = try? NSRegularExpression(pattern: #"^l\.(\d+)\s"#)
    /// `on input line 42` in warnings.
    private static let inputLine = try? NSRegularExpression(pattern: #"on input line (\d+)"#)
    private static let boxLines = try? NSRegularExpression(pattern: #"at lines? (\d+)(?:--(\d+))?"#)
    private static let relatedKey = try? NSRegularExpression(pattern: #"(?:Reference|Citation|Label)\s+[`']([^`']+)'"#, options: .caseInsensitive)
    private static let warningContinuation = try? NSRegularExpression(pattern: #"^(?:\s+\S|\([A-Za-z][A-Za-z0-9_-]*\)\s)"#)
    private static let missingBibKey = try? NSRegularExpression(pattern: #"didn't find a database entry for\s+\"([^\"]+)\""#, options: .caseInsensitive)

    static func diagnostics(in log: String, workingDirectory: URL) -> [BuildDiagnostic] {
        var result: [BuildDiagnostic] = []
        var openStack: [URL?] = []
        var pendingError: BuildDiagnostic?
        var pendingWarningIndex: Int?

        func sourceFile() -> URL? { openStack.reversed().compactMap { $0 }.first }

        func categorize(_ diagnostic: BuildDiagnostic) -> BuildDiagnostic {
            var diagnostic = diagnostic
            let lower = diagnostic.message.lowercased()
            if lower.hasPrefix("overfull") || lower.hasPrefix("underfull") {
                diagnostic.category = .layout
            } else if lower.contains("undefined") && (lower.contains("reference") || lower.contains("citation"))
                        || lower.contains("multiply defined") || lower.contains("multiply-defined") || lower.contains("didn't find a database entry") {
                diagnostic.category = .references
            } else if lower.hasPrefix("warning--") || lower.hasPrefix("warn -") {
                diagnostic.category = .bibliography
            }
            if let regex = relatedKey,
               let match = regex.firstMatch(in: diagnostic.message, range: NSRange(location: 0, length: (diagnostic.message as NSString).length)) {
                diagnostic.relatedKey = (diagnostic.message as NSString).substring(with: match.range(at: 1))
            } else if let regex = missingBibKey,
                      let match = regex.firstMatch(in: diagnostic.message, range: NSRange(location: 0, length: (diagnostic.message as NSString).length)) {
                diagnostic.relatedKey = (diagnostic.message as NSString).substring(with: match.range(at: 1))
            }
            return diagnostic
        }

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

            if let index = pendingWarningIndex {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let continuation = !trimmed.isEmpty && !matches(warningContinuation, line).isEmpty
                if continuation && !trimmed.hasPrefix("!") && !trimmed.hasPrefix("l.") {
                    result[index].message += " " + trimmed
                    result[index].detail += "\n" + line
                    if let match = matches(inputLine, result[index].message).first,
                       let number = group(match, 1, in: result[index].message) {
                        result[index].line = Int(number)
                    }
                    result[index] = categorize(result[index])
                    continue
                }
                pendingWarningIndex = nil
            }

            // Keep ordinary parenthesized text on the stack too, so box dimensions
            // and package messages cannot accidentally close the active source file.
            let openings = Dictionary(uniqueKeysWithValues: matches(openFile, line).map { ($0.range.location, $0) })
            let nsLine = line as NSString
            var cursor = 0
            while cursor < nsLine.length {
                let character = nsLine.character(at: cursor)
                if character == 40 {
                    if let match = openings[cursor], let raw = group(match, 1, in: line) {
                        openStack.append(resolve(raw))
                        cursor += match.range.length
                        continue
                    }
                    openStack.append(nil)
                } else if character == 41, !openStack.isEmpty {
                    openStack.removeLast()
                }
                cursor += 1
            }

            // An error block: remember it, then fill in the file/line from `l.NN`.
            if let pending = pendingError {
                if let match = matches(lineMark, line).first, let number = group(match, 1, in: line) {
                    var filled = pending
                    filled.line = Int(number)
                    if filled.file == nil { filled.file = sourceFile() }
                    filled.detail = (filled.detail + "\n" + line).trimmingCharacters(in: .whitespacesAndNewlines)
                    result.append(categorize(filled))
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
                                                 file: sourceFile(), line: nil, detail: line)
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
                let severity: BuildDiagnostic.Severity = message.localizedCaseInsensitiveContains("warning") || message.hasPrefix("Overfull ") || message.hasPrefix("Underfull ") ? .warning : .error
                result.append(categorize(BuildDiagnostic(severity: severity, message: message, file: url, line: number, detail: line)))
                if severity == .warning { pendingWarningIndex = result.count - 1 }
                continue
            }

            if line.hasPrefix("Overfull ") || line.hasPrefix("Underfull ") {
                var diagnostic = BuildDiagnostic(severity: .warning, message: line, file: sourceFile(), line: nil, detail: line, category: .layout)
                if let match = matches(boxLines, line).first {
                    diagnostic.line = group(match, 1, in: line).flatMap(Int.init)
                    diagnostic.endLine = group(match, 2, in: line).flatMap(Int.init)
                }
                result.append(diagnostic)
                continue
            }

            // Warnings without a file: keep the line number when the log gives one.
            if line.contains("Warning") || line.hasPrefix("WARN -") {
                let message = line.trimmingCharacters(in: .whitespaces)
                guard !message.hasPrefix("(Font)") else { continue }
                guard !message.localizedCaseInsensitiveContains("does not contain any citekeys") else { continue }
                // Using a template by absolute path always produces this one, and it says
                // nothing the writer can act on: "you have requested package X but the
                // package provides Y". Filtered out rather than shown on every build.
                guard !message.contains("You have requested package") else { continue }
                var diagnostic = BuildDiagnostic(severity: .warning, message: message, file: sourceFile(), line: nil, detail: message)
                if let match = matches(inputLine, line).first, let number = group(match, 1, in: line) { diagnostic.line = Int(number) }
                result.append(categorize(diagnostic))
                pendingWarningIndex = result.count - 1
            }
        }
        if let pending = pendingError { result.append(categorize(pending)) }

        // The same problem is often reported twice (latexmk summary + raw TeX log).
        result.removeAll { $0.message.contains("You have requested package") || $0.message.hasPrefix("but the package provides") }
        let hasReferenceDetails = result.contains { $0.category == .references && $0.relatedKey != nil && $0.message.localizedCaseInsensitiveContains("undefined") }
        let hasLabelDetails = result.contains { $0.category == .references && $0.relatedKey != nil && $0.message.localizedCaseInsensitiveContains("multiply defined") }
        result.removeAll {
            (hasReferenceDetails && $0.message.contains("There were undefined references"))
                || (hasLabelDetails && $0.message.contains("There were multiply-defined labels"))
        }
        var seen = Set<String>()
        return result.filter { diagnostic in
            let key = "\(diagnostic.severity.rawValue)|\(diagnostic.file?.path ?? "")|\(diagnostic.line ?? -1)|\(diagnostic.message)"
            return seen.insert(key).inserted
        }
    }

    /// A one-line verdict for the status area.
    static func summary(for diagnostics: [BuildDiagnostic], succeeded: Bool) -> String {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.filter { $0.severity == .warning && !$0.category.isProofreading }.count
        let proofreading = diagnostics.filter { $0.category.isProofreading }.count
        let proofSummary = proofreading > 0 ? " · \(proofreading) proofreading issue\(proofreading == 1 ? "" : "s")" : ""
        if succeeded && errors == 0 {
            return (warnings == 0 ? "Build succeeded" : "Build succeeded · \(warnings) warning\(warnings == 1 ? "" : "s")") + proofSummary
        }
        if errors == 0 { return "Build failed" }
        return "\(errors) error\(errors == 1 ? "" : "s")" + (warnings > 0 ? " · \(warnings) warning\(warnings == 1 ? "" : "s")" : "") + proofSummary
    }

    /// A bibliography step with no citations is harmless. Every other non-zero
    /// exit must participate in the build verdict, including malformed .bib data.
    static func stepFailed(_ step: BuildStep, exitCode: Int32, output: String) -> Bool {
        guard exitCode != 0 else { return false }
        switch step {
        case .latexmk, .engine: return true
        case .biber:
            let noCitations = output.localizedCaseInsensitiveContains("no citekeys") || output.localizedCaseInsensitiveContains("does not contain any citekeys")
            return !(exitCode == 1 && noCitations
                     && !output.localizedCaseInsensitiveContains("ERROR -"))
        case .bibtex:
            let benignPrefixes = ["This is BibTeX", "The top-level auxiliary file:", "The style file:", "Database file #",
                                  "I found no \\citation commands", "I found no \\bibdata command", "I found no \\bibstyle command", "(There was ", "(There were "]
            let noCitations = output.contains("I found no \\citation commands")
            let warningsOnly = exitCode == 1 && output.contains("Warning--") && !output.localizedCaseInsensitiveContains("error message")
            guard noCitations || warningsOnly else { return true }
            return output.split(separator: "\n").contains { line in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && !(warningsOnly && text.hasPrefix("Warning--")) && !benignPrefixes.contains { text.hasPrefix($0) }
            }
        }
    }
}
