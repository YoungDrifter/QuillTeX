import AppKit

extension ProjectStore {
    struct MainSubfileReference: Identifiable, Equatable {
        let url: URL
        let commandRange: NSRange
        let lineRange: NSRange
        let command: String
        var id: String { "\(commandRange.location):" + url.path }
    }
    enum SubfilePlacement: Hashable {
        case before(String), after(String), editorOffset(Int), end
    }
    var mainSubfiles: [MainSubfileReference] {
        guard let root, let main = documents.first(where: { $0.url == root }) else { return [] }
        let ns = main.text as NSString
        return ProjectIndexer.matches(#"\\(?:input|include|subfile)(?:\[[^\]\r\n]*\])?\s*\{([^{}\r\n]+)\}"#,
            in: ProjectIndexer.masked(main.text)).compactMap { match in
            let path = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !path.contains("\\"), !path.contains("#") else { return nil }
            var url = URL(fileURLWithPath: path, relativeTo: root.deletingLastPathComponent()).standardizedFileURL
            if url.pathExtension.isEmpty { url.appendPathExtension("tex") }
            return MainSubfileReference(url: url, commandRange: match.range,
                lineRange: ns.lineRange(for: match.range), command: ns.substring(with: match.range))
        }
    }
    var unlinkedSubfiles: [URL] {
        let included = Set(mainSubfiles.map { $0.url.resolvingSymlinksInPath().path })
        let mainPath = root?.resolvingSymlinksInPath().path
        return Set(index.texFiles + documents.map(\.url)).filter {
            $0.pathExtension.lowercased() == "tex" && $0.resolvingSymlinksInPath().path != mainPath
                && !included.contains($0.resolvingSymlinksInPath().path)
        }.sorted { relativePath($0).localizedStandardCompare(relativePath($1)) == .orderedAscending }
    }

    @discardableResult
    func insertSubfile(_ url: URL, moving referenceID: String? = nil, at placement: SubfilePlacement) throws -> Bool {
        guard subfilesEnabled, let root, let main = documents.first(where: { $0.url == root }), !main.hasMarkedText,
              let base = sourceDirectory ?? directory, ProjectIndexer.isWithin(url, directory: base),
              url.resolvingSymlinksInPath().path != root.resolvingSymlinksInPath().path,
              url.pathExtension.lowercased() == "tex", FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.message("Choose an existing TeX subfile and finish the current input before inserting it.")
        }
        let references = mainSubfiles
        let ns = main.text as NSString
        var offset: Int
        switch placement {
        case .before(let id), .after(let id):
            guard let reference = references.first(where: { $0.id == id }) else {
                throw ProjectError.message("The main file changed during the drag. Try again.")
            }
            if case .before = placement { offset = reference.lineRange.location }
            else { offset = NSMaxRange(reference.lineRange) }
        case .editorOffset(let point):
            let bounded = min(max(0, point), ns.length)
            offset = bounded == ns.length ? bounded : ns.lineRange(for: NSRange(location: bounded, length: 0)).location
        case .end:
            offset = ProjectIndexer.matches(#"\\end\s*\{document\}"#, in: ProjectIndexer.masked(main.text)).last
                .map { ns.lineRange(for: $0.range).location } ?? ns.length
        }
        let path = Self.relativeFilePath(to: url, from: root.deletingLastPathComponent())
        guard path.rangeOfCharacter(from: CharacterSet(charactersIn: "%#{}\\\r\n")) == nil else {
            throw ProjectError.message("This path cannot be used in a literal LaTeX input command.")
        }
        var insertion = "\\input{\(path)}"
        var text = main.text
        if let referenceID {
            guard let moving = references.first(where: { $0.id == referenceID }) else {
                throw ProjectError.message("The main file changed during the drag. Try again.")
            }
            let prefix = ns.substring(with: NSRange(location: moving.lineRange.location, length: moving.commandRange.location - moving.lineRange.location))
            let tail = ns.substring(with: NSRange(location: NSMaxRange(moving.commandRange), length: NSMaxRange(moving.lineRange) - NSMaxRange(moving.commandRange)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let wholeLine = prefix.trimmingCharacters(in: .whitespaces).isEmpty && (tail.isEmpty || tail.hasPrefix("%"))
            let removal = wholeLine ? moving.lineRange : moving.commandRange
            if offset >= removal.location && offset <= NSMaxRange(removal) { return false }
            insertion = wholeLine ? ns.substring(with: removal).trimmingCharacters(in: .newlines) : moving.command
            text = ns.replacingCharacters(in: removal, with: "")
            if offset > removal.location { offset -= removal.length }
        } else if references.contains(where: { $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) {
            throw ProjectError.message("This subfile is already included. Drag its existing reference to move it.")
        }
        let newline = main.text.contains("\r\n") ? "\r\n" : "\n"
        let remaining = text as NSString
        let prefix = offset > 0 && remaining.character(at: offset - 1) != 10 && remaining.character(at: offset - 1) != 13 ? newline : ""
        text = remaining.replacingCharacters(in: NSRange(location: offset, length: 0), with: prefix + insertion + newline)
        applyMetadataText(text, to: main, actionName: referenceID == nil ? "Insert Subfile" : "Move Subfile")
        if main.editorSurface == nil { edited(main) }
        refreshIndex(immediate: true)
        return true
    }

    func previewSubfileInsertion(atScreenPoint point: NSPoint) -> Int? {
        guard subfilesEnabled, let root, let doc = activeDocument, doc.url == root, !doc.hasMarkedText,
              let window, let surface = doc.editorSurface else { clearSubfileInsertionPreview(); return nil }
        let view = surface.textView
        let location = view.convert(window.convertPoint(fromScreen: point), from: nil)
        guard view.visibleRect.contains(location), let layout = view.layoutManager, let container = view.textContainer else {
            clearSubfileInsertionPreview(); return nil
        }
        let local = NSPoint(x: location.x - view.textContainerOrigin.x, y: location.y - view.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        let character = local.y >= layout.usedRect(for: container).maxY || glyph >= layout.numberOfGlyphs
            ? view.string.utf16.count : layout.characterIndexForGlyph(at: glyph)
        let ns = view.string as NSString
        let offset = character == ns.length ? ns.length : ns.lineRange(for: NSRange(location: character, length: 0)).location
        view.subfileInsertionOffset = offset
        return offset
    }
    func clearSubfileInsertionPreview() { documents.forEach { $0.editorSurface?.textView.subfileInsertionOffset = nil } }

}
