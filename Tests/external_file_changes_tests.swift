import AppKit
import PDFKit

@main
struct ExternalFileChangesTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("main.tex")
        let child = directory.appendingPathComponent("child.tex")
        try "Original main".write(to: root, atomically: true, encoding: .utf8)
        try "Original child".write(to: child, atomically: true, encoding: .utf8)
        let library = DocumentLibrary(directory: directory.appendingPathComponent("Library"))
        let store = ProjectStore(library: library)
        store.openProject(root, explicitRoot: true)
        store.openSource(child)
        let main = store.documents[0], other = store.documents[1]
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = EditorSurface(document: other, store: store)
        other.editorSurface = surface
        window.contentView = surface
        store.window = window
        defer { store.finishClosing(); window.close() }
        var checks = 0, decisions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        func settle(_ duration: TimeInterval = 0.7) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !condition(), Date() < deadline { settle(0.05) }
            check(condition(), "file notification arrives without switching applications")
        }
        store.externalChangeDecision = { _ in decisions += 1; return .keepMine }
        try "External 1".write(to: root, atomically: true, encoding: .utf8)
        wait { main.text == "External 1" }
        check(!main.isDirty && decisions == 0, "clean inactive tabs reload without a conflict")
        try "External 2".write(to: root, atomically: true, encoding: .utf8)
        wait { main.text == "External 2" }
        let handle = try FileHandle(forWritingTo: root)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("In-place update".utf8)); try handle.close()
        wait { main.text == "In-place update" }
        other.selection = NSRange(location: 2, length: 3)
        try "Child external update".write(to: child, atomically: true, encoding: .utf8)
        wait { surface.textView.string == "Child external update" }
        check(other.selection == NSRange(location: 2, length: 3), "external reload keeps a valid model selection")

        other.text = "My unsaved edits"
        try "External conflicting edit".write(to: child, atomically: true, encoding: .utf8)
        wait { decisions == 1 }
        check(other.text == "My unsaved edits" && other.isDirty, "keep mine preserves the unsaved buffer")
        check((try? String(contentsOf: child, encoding: .utf8)) == "External conflicting edit", "keep mine does not overwrite disk")
        settle()
        check(decisions == 1, "the same external revision is not prompted repeatedly")
        store.persistSession(); store.sessionStore.flush()
        check(store.sessionStore.load(root: root)?.documents.first { $0.path == child.path }?.diskText == "External conflicting edit",
              "the acknowledged conflict baseline is persisted for recovery")
        store.externalChangeDecision = { _ in decisions += 1; return .useExternal }
        try "Chosen external version".write(to: child, atomically: true, encoding: .utf8)
        wait { other.text == "Chosen external version" }
        check(!other.isDirty && decisions == 2, "a later conflict offers the choice again")
        other.text = "Converged contents"
        try other.text.write(to: child, atomically: true, encoding: .utf8)
        wait { !other.isDirty }
        check(decisions == 2, "identical local and external edits need no conflict dialog")

        other.text = "Save mine"
        try "Save conflict".write(to: child, atomically: true, encoding: .utf8)
        store.externalChangeDecision = { _ in decisions += 1; return .keepMine }
        check(store.save(other), "save uses the keep-mine decision before overwriting")
        check((try? String(contentsOf: child, encoding: .utf8)) == "Save mine", "explicit save writes the chosen local version")
        other.text = "Discard this local edit"
        try "Use this external edit".write(to: child, atomically: true, encoding: .utf8)
        store.externalChangeDecision = { _ in decisions += 1; return .useExternal }
        check(store.save(other) && other.text == "Use this external edit", "save can choose the external version instead")
        check((try? String(contentsOf: child, encoding: .utf8)) == other.text, "choosing external never writes the discarded local text")

        var races = 0
        other.text = "Local during prompt"
        try "First prompt version".write(to: child, atomically: true, encoding: .utf8)
        store.externalChangeDecision = { _ in
            races += 1
            if races == 1 { try! "Latest prompt version".write(to: child, atomically: true, encoding: .utf8) }
            return .useExternal
        }
        store.checkExternalChanges()
        check(races == 2 && other.text == "Latest prompt version", "a change during the prompt is rechecked before accepting")
        other.hasMarkedText = true
        try "After input composition".write(to: child, atomically: true, encoding: .utf8)
        settle()
        check(other.text == "Latest prompt version", "external updates do not interrupt marked input")
        other.hasMarkedText = false
        wait { other.text == "After input composition" }
        try FileManager.default.removeItem(at: child)
        settle(0.35)
        try "Recreated child".write(to: child, atomically: true, encoding: .utf8)
        wait { other.text == "Recreated child" }

        other.text = "Local conflict in second tab"
        try "Second tab external".write(to: child, atomically: true, encoding: .utf8)
        store.externalChangeDecision = { _ in
            try! "First tab changed during prompt".write(to: root, atomically: true, encoding: .utf8)
            store.checkExternalChanges()
            return .useExternal
        }
        store.checkExternalChanges()
        wait { main.text == "First tab changed during prompt" }
        check(other.text == "Second tab external", "changes arriving during another tab's prompt are not lost")

        func pdf(_ color: NSColor) -> Data {
            let image = NSImage(size: NSSize(width: 200, height: 300))
            image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 200, height: 300).fill(); image.unlockFocus()
            let document = PDFDocument(); document.insert(PDFPage(image: image)!, at: 0)
            return document.dataRepresentation()!
        }
        let output = store.expectedPDF!
        let first = pdf(.white), second = pdf(.gray)
        try first.write(to: output, options: .atomic)
        wait { store.build.pdfURL == output }
        let version = store.build.pdfVersion
        try Data("Incomplete PDF".utf8).write(to: output)
        settle()
        check(store.build.pdfVersion == version, "invalid external PDF output keeps the last good preview")
        try second.write(to: output, options: .atomic)
        wait { store.build.pdfVersion > version }
        let refreshed = store.build.pdfVersion
        store.checkExternalChanges()
        check(store.build.pdfVersion == refreshed, "identical PDF bytes do not rebuild the preview")
        store.finishClosing()
        try "After closing".write(to: root, atomically: true, encoding: .utf8)
        settle()
        check(main.text == "First tab changed during prompt", "closed workspaces stop monitoring their files")
        print("PASS: \(checks) external-file assertions")
    }
}
