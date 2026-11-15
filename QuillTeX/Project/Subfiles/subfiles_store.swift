import AppKit

extension ProjectStore {
    enum TeXFileRole: String, CaseIterable, Hashable {
        case main = "Main"
        case sub = "Sub"
        case other = "Others"
    }

    private var relatedTeXFiles: [URL] {
        var files = Set(index.texFiles.map(\.standardizedFileURL) + documents.map { $0.url.standardizedFileURL })
        if let root { files.insert(root.standardizedFileURL) }
        return files.filter { $0.pathExtension.lowercased() == "tex" }
            .sorted { relativePath($0).localizedStandardCompare(relativePath($1)) == .orderedAscending }
    }

    private func sourceText(for url: URL) -> String? {
        documents.first { $0.url == url.standardizedFileURL }?.text
            ?? (try? String(contentsOf: url, encoding: .utf8))
    }

    private func declaredRoot(for url: URL) -> URL? {
        guard let text = sourceText(for: url), let path = ProjectIndexer.rootDirective(in: text) else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath,
                   relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    var mainTeXFiles: [URL] { root.map { [$0] } ?? [] }
    var subTeXFiles: [URL] {
        guard let root else { return [] }
        return relatedTeXFiles.filter { $0 != root && declaredRoot(for: $0) == root }
    }
    var otherTeXFiles: [URL] {
        let main = Set(mainTeXFiles), sub = Set(subTeXFiles)
        return relatedTeXFiles.filter { !main.contains($0) && !sub.contains($0) }
    }

    static func removingRootDirectives(from text: String) -> String {
        let literal = LaTeXHighlighter.spans(in: text).filter { $0.token == .verbatim }
        let matches = ProjectIndexer.matches(#"(?im)^(?:\x{FEFF})?[\t ]*%[\t ]*![\t ]*tex[\t ]+root[\t ]*=[^\r\n]*(?:\r\n|\n|\r)?"#, in: text)
            .filter { match in !literal.contains { NSIntersectionRange($0.range, match.range).length > 0 } }
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in matches.reversed() { result.deleteCharacters(in: match.range) }
        if text.hasPrefix("\u{FEFF}"), !(result as String).hasPrefix("\u{FEFF}") { result.insert("\u{FEFF}", at: 0) }
        return result as String
    }

    @discardableResult
    func setTeXFile(_ url: URL, role: TeXFileRole) throws -> Bool {
        guard texProjectEnabled, let root else {
            throw ProjectError.message("Enable TeX Project before changing file relationships.")
        }
        let url = url.standardizedFileURL
        guard url.pathExtension.lowercased() == "tex", let base = sourceDirectory ?? directory,
              ProjectIndexer.isWithin(url, directory: base), FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.message("Choose an existing TeX file in this project.")
        }
        if role == .main {
            guard url != root else { return false }
            openProject(url, explicitRoot: true)
            return self.root == url
        }
        guard url != root else {
            throw ProjectError.message("Choose another file as Main before moving the current Main file.")
        }
        let document: SourceDocument
        if let existing = documents.first(where: { $0.url == url }) { document = existing }
        else {
            document = SourceDocument(url: url, text: try String(contentsOf: url, encoding: .utf8))
            documents.append(document)
        }
        guard !document.hasMarkedText else {
            throw ProjectError.message("Finish the current input method composition before changing this file.")
        }
        let updated: String
        switch role {
        case .main: return false
        case .sub:
            let path = Self.relativeFilePath(to: root, from: url.deletingLastPathComponent())
            updated = Self.updatingRootDirective(in: document.text, to: path, replacingExisting: true)
        case .other:
            updated = Self.removingRootDirectives(from: document.text)
        }
        guard updated != document.text else { return false }
        applyMetadataText(updated, to: document,
                          actionName: role == .sub ? "Add Main File Comment" : "Remove Main File Comment")
        if document.editorSurface == nil { edited(document) }
        openSource(url)
        refreshIndex(immediate: true)
        scheduleSessionSave()
        objectWillChange.send()
        return true
    }
}
