import AppKit
import Foundation

@main
struct WorkspaceSessionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultsSuite = "QuillTeX.WorkspaceSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let root = directory.appendingPathComponent("main.tex")
        let child = directory.appendingPathComponent("中文 child.tex")
        let missing = directory.appendingPathComponent("removed.tex")
        try "\\documentclass{article}\nOriginal main".write(to: root, atomically: true, encoding: .utf8)
        try "Original child".write(to: child, atomically: true, encoding: .utf8)
        try "Removed child".write(to: missing, atomically: true, encoding: .utf8)
        let library = DocumentLibrary(directory: directory.appendingPathComponent("Library"),
                                      bundledTemplatesDirectory: URL(fileURLWithPath: "QuillTeX/Project/bundled_templates"))
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        let original = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        original.openProject(root, explicitRoot: true)
        original.openSource(child)
        original.openSource(missing)
        let deleted = original.activeDocument!
        deleted.text += " unsaved"
        original.activate(original.documents.first { $0.url == child }!)
        let draft = original.activeDocument!
        draft.text += " 中文 😀"
        draft.selection = NSRange(location: 2, length: 3)
        draft.scrollOrigin = CGPoint(x: 0, y: 350)
        original.sidebarVisible = false
        original.sidebarMode = .folder
        original.paneMode = .editor
        original.expandedNodes = ["contents", "folder:example"]
        original.sidebarWidth = 315
        original.editorFraction = 0.64
        original.pdfReadingState = PDFReadingState(pageIndex: 4, topPoint: CGPoint(x: 12, y: 90), scale: 1.25, zoomMode: .manual)
        original.persistSession()
        original.sessionStore.flush()
        try "Changed externally".write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: missing)
        let recovered = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        recovered.openProject(root, explicitRoot: true)
        check(recovered.documents.map(\.url) == [root, child, missing], "restore opened documents and recover a deleted dirty file")
        check(recovered.activeDocument?.url == child, "restore active file")
        check(recovered.activeDocument?.text == draft.text, "recover unsaved Unicode draft")
        check(recovered.activeDocument?.isDirty == true, "recovery does not pretend the draft was saved")
        check(recovered.activeDocument?.diskText == "Original child", "keep conflict baseline for an external change during downtime")
        let externalText = try String(contentsOf: child, encoding: .utf8)
        check(externalText == "Changed externally", "recovery never overwrites source on disk")
        check(!FileManager.default.fileExists(atPath: missing.path), "recovering a deleted buffer does not recreate its file")
        check(recovered.activeDocument?.selection == draft.selection, "restore complete selection")
        check(recovered.activeDocument?.scrollOrigin.y == 350, "restore editor scroll position")
        check(!recovered.sidebarVisible && recovered.sidebarMode == .folder && recovered.paneMode == .editor, "restore pane modes")
        check(recovered.expandedNodes == original.expandedNodes, "restore expanded branches")
        check(recovered.sidebarWidth == 315 && recovered.editorFraction == 0.5, "restore the sidebar width and open the editor/preview split equal")
        check(recovered.pdfReadingState == original.pdfReadingState, "restore PDF position and manual zoom")
        check(recovered.recoveryMessage != nil, "make recovered edits visible")
        recovered.activeDocument!.hasMarkedText = true
        recovered.activeDocument!.text += " composing"
        recovered.persistSession()
        recovered.sessionStore.flush()
        check(recovered.sessionStore.load(root: root)?.documents.first { $0.path == child.path }?.draft == draft.text, "IME composition never replaces stable recovery data")
        recovered.finishClosing()
        let reopened = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        reopened.openProject(root, explicitRoot: true)
        check(reopened.activeDocument?.text == "Changed externally", "normal close with discarded drafts restores disk contents")
        check(!reopened.documents.contains { $0.url == missing }, "missing clean tabs are skipped")
        check(!reopened.documents.contains { $0.isDirty }, "discarded edits do not return")
        // The pane buttons are mode switches: only entering the split equalizes
        // once; clicking the active Editor + PDF must not nudge the divider.
        reopened.paneMode = .editor
        let versionBeforeSplit = reopened.splitLayoutVersion
        reopened.showEditorAndPDF()
        check(reopened.paneMode == .split && reopened.splitLayoutVersion == versionBeforeSplit + 1,
              "Editor Only to Editor + PDF requests the split once")
        reopened.paneMode = .preview
        let versionBeforeSecondSplit = reopened.splitLayoutVersion
        reopened.showEditorAndPDF()
        check(reopened.paneMode == .split && reopened.splitLayoutVersion == versionBeforeSecondSplit + 1,
              "PDF Only to Editor + PDF requests the split once")
        let versionWhileSplit = reopened.splitLayoutVersion
        reopened.showEditorAndPDF()
        check(reopened.paneMode == .split && reopened.splitLayoutVersion == versionWhileSplit,
              "clicking the active Editor + PDF never re-equalizes the divider")
        let session = reopened.sessionStore.load(root: root)!
        var invalid = session
        invalid.version = 99
        reopened.sessionStore.save(invalid)
        reopened.sessionStore.flush()
        check(reopened.sessionStore.load(root: root) == nil, "unsupported sessions do not change document opening")
        var bounded = session
        bounded.sidebarWidth = 1_000_000
        bounded.documents[0].selectionLocation = Int.max
        bounded.documents[0].selectionLength = Int.max
        reopened.sessionStore.save(bounded)
        reopened.sessionStore.flush()
        let clamped = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        clamped.openProject(root, explicitRoot: true)
        check(clamped.sidebarWidth == 400 && clamped.editorFraction == 0.5, "clamp the legacy session sidebar width and open the split equal")
        // The dragged width is an app-wide preference now: it wins over the
        // width stored with an older project session and survives relaunch.
        defaults.set(347, forKey: ProjectStore.sidebarWidthDefaultsKey)
        let widthStore = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        check(widthStore.sidebarWidth == 347, "load the app-wide sidebar width at launch")
        widthStore.openProject(root, explicitRoot: true)
        check(widthStore.sidebarWidth == 347, "opening a project keeps the app-wide sidebar width")
        widthStore.setSidebarWidth(1_000_000)
        check(widthStore.sidebarWidth == 400 && defaults.double(forKey: ProjectStore.sidebarWidthDefaultsKey) == 400,
              "clamp and persist a dragged sidebar width")
        widthStore.setSidebarWidth(10)
        check(widthStore.sidebarWidth == 180 && defaults.double(forKey: ProjectStore.sidebarWidthDefaultsKey) == 180,
              "clamp tiny sidebar widths and persist them too")
        let main = clamped.documents.first!
        check(main.selection.location == (main.text as NSString).length && main.selection.length == 0, "clamp restored selection to current file")
        main.text += "\nUnsaved main draft"
        clamped.persistSession()
        clamped.sessionStore.flush()
        try FileManager.default.removeItem(at: root)
        check(clamped.sessionStore.lastWorkspace() == root, "a deleted main file with a draft remains recoverable at launch")
        let deletedMain = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        deletedMain.openProject(root)
        check(deletedMain.root == root && deletedMain.documents.first?.text == main.text, "recover the deleted main buffer without reading its missing file")
        check(deletedMain.documents.first?.isDirty == true && !FileManager.default.fileExists(atPath: root.path), "deleted main recovery preserves the source and unsaved state")
        let first = directory.appendingPathComponent("first.tex")
        let second = directory.appendingPathComponent("second.tex")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)
        let promoted = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        promoted.openProject(first, explicitRoot: true)
        promoted.activeDocument!.text += " unsaved"
        promoted.persistSession(); promoted.sessionStore.flush()
        do { try promoted.selectMainFile(second); fatalError("fixed main file changed") }
        catch { check(promoted.root == first, "same-directory files cannot replace the fixed main file") }
        check(promoted.sessionStore.load(root: first)?.documents.first?.draft == "First unsaved", "a rejected main change keeps the original workspace draft")
        check(promoted.sessionStore.load(root: second) == nil && promoted.activeDocument?.text == "First unsaved", "a rejected main change creates no replacement session and preserves the active buffer")
        promoted.finishClosing()
        let afterDiscard = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        afterDiscard.openProject(first, explicitRoot: true)
        check(afterDiscard.activeDocument?.text == "First" && afterDiscard.activeDocument?.isDirty == false, "discard after a rejected main change clears the original draft")
        afterDiscard.openProject(second, explicitRoot: true)
        check(afterDiscard.root == second && afterDiscard.activeDocument?.text == "Second", "main locking still permits explicitly opening a separate project")
        afterDiscard.finishClosing()
        let previousMode = BuildSettings.shared.mode
        BuildSettings.shared.mode = .manual
        defer { BuildSettings.shared.mode = previousMode }
        let revisionStore = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        revisionStore.openProject(first, explicitRoot: true)
        let fakeEngine = directory.appendingPathComponent("delayed-engine")
        try "#!/bin/sh\nsleep 0.3\necho done\n".write(to: fakeEngine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeEngine.path)
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("preview fixture".utf8).write(to: output.appendingPathComponent("first.pdf"))
        func request(_ revision: Int) -> BuildController.Request {
            BuildController.Request(mainFile: first, outputDirectory: output, engine: .xelatex,
                steps: [.engine], toolPaths: ["xelatex": fakeEngine.path],
                environment: ProcessInfo.processInfo.environment, sourceRevision: revision)
        }
        revisionStore.build.compile(request(0))
        revisionStore.activeDocument!.text += " revision one"
        revisionStore.edited(revisionStore.activeDocument!)
        revisionStore.build.compile(request(1))
        revisionStore.activeDocument!.text += " revision two"
        revisionStore.edited(revisionStore.activeDocument!)
        let deadline = Date().addingTimeInterval(4)
        while revisionStore.build.status.isRunning, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        check(!revisionStore.build.status.isRunning && revisionStore.build.activeSourceRevision == 1, "queued build keeps its own saved source revision")
        check(revisionStore.previewStatusText == "PDF is awaiting compilation", "a queued build cannot mark newer unsaved edits as compiled")
        revisionStore.syncStatusMessage = "Locating in PDF…"
        revisionStore.build.adoptExistingPDF(output.appendingPathComponent("first.pdf"))
        check(revisionStore.syncStatusMessage == nil, "a replacement PDF clears an obsolete location request")
        let label = NavigationNode(id: "duplicate", title: "eq:duplicate", kind: .label, url: first)
        revisionStore.index.structure = [label]
        let duplicate = BuildDiagnostic(severity: .warning, message: "Label eq:duplicate multiply defined.", file: nil, line: nil, category: .references, relatedKey: "eq:duplicate")
        check(revisionStore.resolvedDiagnostic(duplicate)?.file == first, "duplicate labels without log locations can use the structure index")
        // Renaming the main document carries the compiled outputs with it so the
        // preview and SyncTeX keep pointing at the same build.
        let renameRoot = directory.appendingPathComponent("rename-main.tex")
        try "\\documentclass{article}".write(to: renameRoot, atomically: true, encoding: .utf8)
        try Data("pdf".utf8).write(to: directory.appendingPathComponent("rename-main.pdf"))
        try Data("aux".utf8).write(to: directory.appendingPathComponent("rename-main.aux"))
        try Data("sync".utf8).write(to: directory.appendingPathComponent("rename-main.synctex.gz"))
        let renameStore = ProjectStore(library: library, maintainsRootDirectives: false, defaults: defaults)
        renameStore.openProject(renameRoot, explicitRoot: true)
        let renamedMain = directory.appendingPathComponent("renamed-main.tex")
        try renameStore.updateActiveFile(renamedMain, tags: [])
        let renamedPDF = directory.appendingPathComponent("renamed-main.pdf")
        check(renameStore.root == renamedMain, "renaming the main document updates the project root")
        check(FileManager.default.fileExists(atPath: renamedPDF.path), "main rename carries the compiled PDF")
        check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("renamed-main.aux").path), "main rename carries the auxiliary file")
        check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("renamed-main.synctex.gz").path), "main rename carries the SyncTeX file")
        check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("rename-main.pdf").path), "the old PDF name is gone after rename")
        check(renameStore.build.pdfURL?.standardizedFileURL == renamedPDF.standardizedFileURL, "the preview follows the renamed PDF")
        print("WorkspaceSessionTests: \(checks) assertions passed")
    }
}
