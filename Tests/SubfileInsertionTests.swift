import AppKit

@main
struct SubfileInsertionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subfile-drag-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("main.tex")
        let a = directory.appendingPathComponent("a.tex"), b = directory.appendingPathComponent("b.tex"), c = directory.appendingPathComponent("c.tex")
        for url in [a,b,c] { try "Child".write(to: url, atomically: true, encoding: .utf8) }
        let initial = "Intro\n\\input{b}\n% after-b notes\n\\section{Between}\n\\include{a} % keep-a\n\\end{document}\n"
        try initial.write(to: root, atomically: true, encoding: .utf8)
        let store = ProjectStore(library: DocumentLibrary(directory: directory.appendingPathComponent("Library")), maintainsRootDirectives: false)
        store.openProject(root, explicitRoot: true)
        store.index = ProjectIndexer(root: root, overrides: [:]).build()
        defer { store.finishClosing() }
        let doc = store.activeDocument!
        let surface = EditorSurface(document: doc, store: store)
        doc.editorSurface = surface
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface
        window.orderFront(nil)
        defer { window.close() }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }; checks += 1
        }
        func reset(_ text: String = initial) {
            doc.text = text; doc.savedText = text; doc.diskText = initial
            doc.selection = NSRange(location: 0, length: 0)
            surface.reloadFromDisk()
            while doc.undoManager.groupingLevel > 0 { doc.undoManager.endUndoGrouping() }
        }
        check(store.mainSubfiles.map(\.url.lastPathComponent) == ["b.tex","a.tex"], "subfiles follow source order rather than filename sorting")
        check(store.unlinkedSubfiles == [c], "unlinked TeX files form a separate collection")
        let bID = store.mainSubfiles[0].id, aID = store.mainSubfiles[1].id
        try store.insertSubfile(c, at: .after(bID))
        let afterB = doc.text
        check(afterB.contains("\\input{b}\n\\input{c.tex}\n% after-b notes\n"), "after-b insertion occurs on the immediately following line")
        check((try? String(contentsOf: root, encoding: .utf8)) == initial, "drag insertion leaves the main file unsaved")
        while doc.undoManager.groupingLevel > 0 { doc.undoManager.endUndoGrouping() }
        doc.undoManager.undo()
        check(doc.text == initial && surface.textView.string == initial, "one undo restores the main file before insertion")
        reset()
        try store.insertSubfile(c, at: .before(aID))
        check(doc.text.contains("\\section{Between}\n\\input{c.tex}\n\\include{a}"), "before-a insertion happens after the intervening section")
        check(doc.text != afterB, "after the previous subfile and before the next subfile remain distinct anchors")
        check(store.unlinkedSubfiles.isEmpty, "an inserted file moves out of the unlinked section immediately")
        let unchanged = doc.text
        do { try store.insertSubfile(c, at: .end); fatalError("duplicate inserted") }
        catch { check(doc.text == unchanged, "dropping an already included unlinked item cannot duplicate it") }
        reset()
        try store.insertSubfile(a, moving: aID, at: .before(bID))
        check(store.mainSubfiles.map(\.url.lastPathComponent) == ["a.tex","b.tex"], "dragging an existing subfile moves its original reference")
        check(doc.text.hasPrefix("Intro\n\\include{a} % keep-a\n\\input{b}"), "moving a reference keeps its command spelling and trailing comment")
        check(doc.text.contains("% after-b notes\n\\section{Between}\n\\end{document}"), "moving a reference preserves intervening body text")
        reset()
        check(!(try! store.insertSubfile(b, moving: bID, at: .after(bID))), "dropping a reference at its own boundary is a no-op")
        let line = (initial as NSString).range(of: "% after-b notes").location
        try store.insertSubfile(c, at: .editorOffset(line + 5))
        check(doc.text.contains("\\input{b}\n\\input{c.tex}\n% after-b notes"), "dropping onto a source line inserts before that line")
        reset()
        try store.insertSubfile(c, at: .end)
        check(doc.text.contains("\\include{a} % keep-a\n\\input{c.tex}\n\\end{document}"), "the empty-list target inserts before end document")
        reset("Before \\input{b} after\n\\include{a}\n")
        let inlineID = store.mainSubfiles[0].id
        try store.insertSubfile(b, moving: inlineID, at: .end)
        check(doc.text.hasPrefix("Before  after\n") && doc.text.hasSuffix("\\input{b}\n"), "moving an inline reference does not remove surrounding prose")
        reset("\\input{b}\r\nBody\r\n\\end{document}\r\n")
        try store.insertSubfile(c, at: .after(store.mainSubfiles[0].id))
        check(doc.text.contains("\\input{b}\r\n\\input{c.tex}\r\nBody"), "drag insertion preserves CRLF line endings")
        reset("% \\input{c}\n\\begin{verbatim}\\input{c}\\end{verbatim}\n\\input{b}\n")
        check(store.mainSubfiles.map(\.url) == [b], "comment and literal examples do not become drag anchors")
        reset()
        do { try store.insertSubfile(root, at: .end); fatalError("main included itself") }
        catch { check(doc.text == initial, "the main file cannot be inserted as its own subfile") }
        do { try store.insertSubfile(c, at: .before("obsolete anchor")); fatalError("stale anchor used") }
        catch { check(doc.text == initial, "stale references never insert at a guessed position") }
        doc.hasMarkedText = true
        do { try store.insertSubfile(c, at: .end); fatalError("interrupted IME") }
        catch { check(doc.text == initial, "drag insertion does not interrupt marked text") }
        doc.hasMarkedText = false
        store.window = window
        surface.textView.layoutManager?.ensureLayout(for: surface.textView.textContainer!)
        let screen = window.convertPoint(toScreen: surface.textView.convert(NSPoint(x: 120, y: 45), to: nil))
        check(store.previewSubfileInsertion(atScreenPoint: screen) != nil, "dragging over the visible main editor provides a source insertion target")
        check(surface.textView.subfileInsertionOffset != nil, "the source editor exposes an insertion-line preview")
        store.clearSubfileInsertionPreview()
        check(surface.textView.subfileInsertionOffset == nil, "ending or cancelling a drag removes its source preview")
        print("PASS: \(checks) subfile-insertion assertions")
    }
}
