import AppKit
import Foundation

@main
struct WorkspaceSessionTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("main.tex")
        let child = directory.appendingPathComponent("中文 child.tex")
        let missing = directory.appendingPathComponent("removed.tex")
        try "\\documentclass{article}\nOriginal main".write(to: root, atomically: true, encoding: .utf8)
        try "Original child".write(to: child, atomically: true, encoding: .utf8)
        try "Removed child".write(to: missing, atomically: true, encoding: .utf8)
        let library = DocumentLibrary(directory: directory.appendingPathComponent("Library"),
                                      bundledTemplatesDirectory: URL(fileURLWithPath: "QuillTeX/Project/BundledTemplates"))
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        let original = ProjectStore(library: library)
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
        original.setTabBarVisible(false)
        original.expandedNodes = ["contents", "folder:example"]
        original.sidebarWidth = 315
        original.editorFraction = 0.64
        original.pdfReadingState = PDFReadingState(pageIndex: 4, topPoint: CGPoint(x: 12, y: 90), scale: 1.25, zoomMode: .manual)
        original.persistSession()
        original.sessionStore.flush()
        try "Changed externally".write(to: child, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: missing)
        let recovered = ProjectStore(library: library)
        recovered.openProject(root, explicitRoot: true)
        check(recovered.documents.map(\.url) == [root, child, missing], "restore ordered tabs and recover a deleted dirty file")
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
        check(!recovered.isTabBarVisible && recovered.expandedNodes == original.expandedNodes, "restore tabs visibility and expanded branches")
        check(recovered.sidebarWidth == 315 && recovered.editorFraction == 0.64, "restore independent divider positions")
        check(recovered.pdfReadingState == original.pdfReadingState, "restore PDF position and manual zoom")
        check(recovered.recoveryMessage != nil, "make recovered edits visible")
        recovered.activeDocument!.hasMarkedText = true
        recovered.activeDocument!.text += " composing"
        recovered.persistSession()
        recovered.sessionStore.flush()
        check(recovered.sessionStore.load(root: root)?.documents.first { $0.path == child.path }?.draft == draft.text, "IME composition never replaces stable recovery data")
        recovered.finishClosing()
        let reopened = ProjectStore(library: library)
        reopened.openProject(root, explicitRoot: true)
        check(reopened.activeDocument?.text == "Changed externally", "normal close with discarded drafts restores disk contents")
        check(!reopened.documents.contains { $0.url == missing }, "missing clean tabs are skipped")
        check(!reopened.documents.contains { $0.isDirty }, "discarded edits do not return")
        let session = reopened.sessionStore.load(root: root)!
        var invalid = session
        invalid.version = 99
        reopened.sessionStore.save(invalid)
        reopened.sessionStore.flush()
        check(reopened.sessionStore.load(root: root) == nil, "unsupported sessions do not change document opening")
        var bounded = session
        bounded.sidebarWidth = 1_000_000
        bounded.editorFraction = -5
        bounded.documents[0].selectionLocation = Int.max
        bounded.documents[0].selectionLength = Int.max
        reopened.sessionStore.save(bounded)
        reopened.sessionStore.flush()
        let clamped = ProjectStore(library: library)
        clamped.openProject(root, explicitRoot: true)
        check(clamped.sidebarWidth == 400 && clamped.editorFraction == 0.15, "clamp saved geometry")
        let main = clamped.documents.first!
        check(main.selection.location == (main.text as NSString).length && main.selection.length == 0, "clamp restored selection to current file")
        main.text += "\nUnsaved main draft"
        clamped.persistSession()
        clamped.sessionStore.flush()
        try FileManager.default.removeItem(at: root)
        check(clamped.sessionStore.lastWorkspace() == root, "a deleted main file with a draft remains recoverable at launch")
        let deletedMain = ProjectStore(library: library)
        deletedMain.openProject(root)
        check(deletedMain.root == root && deletedMain.documents.first?.text == main.text, "recover the deleted main buffer without reading its missing file")
        check(deletedMain.documents.first?.isDirty == true && !FileManager.default.fileExists(atPath: root.path), "deleted main recovery preserves the source and unsaved state")
        let first = directory.appendingPathComponent("first.tex")
        let second = directory.appendingPathComponent("second.tex")
        try "First".write(to: first, atomically: true, encoding: .utf8)
        try "Second".write(to: second, atomically: true, encoding: .utf8)
        let promoted = ProjectStore(library: library)
        promoted.openProject(first, explicitRoot: true)
        promoted.activeDocument!.text += " unsaved"
        promoted.persistSession(); promoted.sessionStore.flush()
        try promoted.selectMainFile(second)
        check(promoted.sessionStore.load(root: first)?.documents.first?.draft == nil, "main promotion retires the previous recovery draft only after saving its new workspace")
        check(promoted.sessionStore.load(root: second)?.documents.first { $0.path == first.path }?.draft == "First unsaved", "promotion keeps the draft in the new workspace")
        promoted.finishClosing()
        let afterDiscard = ProjectStore(library: library)
        afterDiscard.openProject(first, explicitRoot: true)
        check(afterDiscard.activeDocument?.text == "First" && afterDiscard.activeDocument?.isDirty == false, "discard after main promotion does not resurrect an old session draft")
        let previousMode = BuildSettings.shared.mode
        BuildSettings.shared.mode = .manual
        defer { BuildSettings.shared.mode = previousMode }
        let revisionStore = ProjectStore(library: library)
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
        print("WorkspaceSessionTests: \(checks) assertions passed")
    }
}
