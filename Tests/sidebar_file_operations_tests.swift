import AppKit

@main
struct SidebarFileOperationsTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sidebar-\(UUID())", isDirectory: true)
        let directory = base.appendingPathComponent("Project", isDirectory: true)
        let chapters = directory.appendingPathComponent("chapters", isDirectory: true)
        let empty = chapters.appendingPathComponent("empty", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for folder in [empty, outside, directory.appendingPathComponent("build"), directory.appendingPathComponent(".git")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let root = directory.appendingPathComponent("main.tex")
        let child = chapters.appendingPathComponent("child.tex")
        let stale = directory.appendingPathComponent("stale.tex")
        let original = "% !TeX program = xelatex\n\\documentclass{article}\n\\begin{document}\nBody\n\\end{document}\n"
        try original.write(to: root, atomically: true, encoding: .utf8)
        try "Chinese child\r\n".write(to: child, atomically: true, encoding: .utf8)
        try "% !TeX root = other.tex\nStale".write(to: stale, atomically: true, encoding: .utf8)
        let ignored = [directory.appendingPathComponent("build/generated.tex"), directory.appendingPathComponent(".git/hidden.tex"), outside.appendingPathComponent("external.tex")]
        for file in ignored { try "Unchanged".write(to: file, atomically: true, encoding: .utf8) }
        try fm.createSymbolicLink(at: directory.appendingPathComponent("linked"), withDestinationURL: outside)
        let library = DocumentLibrary(directory: directory.appendingPathComponent("Library"))
        let libraryFile = library.directory.appendingPathComponent("private.tex")
        try "Library data".write(to: libraryFile, atomically: true, encoding: .utf8)
        let store = ProjectStore(library: library)
        defer { store.finishClosing() }
        store.openProject(root)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }; checks += 1
        }
        func disk(_ url: URL) -> String { try! String(contentsOf: url, encoding: .utf8) }
        check(disk(root) == "% !TeX root = main.tex\n" + original, "opening adds a first-line root directive and preserves the compiler directive")
        check(disk(child) == "% !TeX root = ../main.tex\r\nChinese child\r\n", "unopened nested TeX files receive relative comments with their original line endings")
        check(disk(stale).hasPrefix("% !TeX root = other.tex"), "opening only fills missing comments")
        check(ignored.allSatisfy { disk($0) == "Unchanged" } && disk(libraryFile) == "Library data", "hidden, build, app-data and external symlink files stay untouched")
        check(!store.activeDocument!.isDirty, "adding comments does not leave a clean document falsely dirty")
        let once = disk(root)
        store.openProject(root)
        check(disk(root) == once, "reopening does not duplicate comments")
        let literal = "\\begin{verbatim}\n% !TeX root = example.tex\n\\end{verbatim}\n"
        check(ProjectStore.updatingRootDirective(in: literal, to: "main.tex", replacingExisting: true) == "% !TeX root = main.tex\n" + literal,
              "example comments inside literal environments are not rewritten")
        check(ProjectStore.updatingRootDirective(in: "\u{FEFF}% !TeX root = old.tex\r\nText", to: "new.tex", replacingExisting: true)
                == "\u{FEFF}% !TeX root = new.tex\r\nText", "BOM and CRLF survive updating an existing directive")

        store.sidebarMode = .folder
        check(store.creationDirectory?.path == directory.path, "trees without expanded child folders create in the project root")
        store.toggleFolder(directory)
        check(store.isProjectRootFolder(directory) && !store.expandedNodes.contains(ProjectStore.folderExpansionKey(directory)), "the project root never becomes a collapsible branch")
        store.toggleFolder(chapters); store.toggleFolder(empty)
        check(store.creationDirectory?.path == empty.path, "empty folders can be opened and used as creation targets")
        store.toggleFolder(chapters)
        check(store.creationDirectory?.path == directory.path, "collapsing an ancestor excludes its hidden expanded descendants")
        store.toggleFolder(chapters)
        check(store.creationDirectory?.path == chapters.path, "the latest visibly opened folder receives new items")
        let folder = try store.createFolder(named: "new folder", in: store.creationDirectory!)
        check(folder.deletingLastPathComponent().path == chapters.path && fm.fileExists(atPath: folder.path), "new folders use the current target without choosing a location")
        let fresh = try store.createTeXFile(named: "fresh", in: chapters)
        check(fresh.lastPathComponent == "fresh.tex" && store.activeDocument?.url == fresh, "file creation appends tex and opens the buffer")
        check(disk(fresh).hasPrefix("% !TeX root = ../main.tex\n"), "new subfiles always start with the current root comment")
        let oldMain = store.documents.first { $0.url == root }!
        check(oldMain.text.contains("\\input{chapters/fresh.tex}"), "new subfiles retain the existing input-link workflow")
        let beforeDuplicate = disk(fresh)
        do { try store.createTeXFile(named: "fresh.tex", in: chapters); fatalError("duplicate overwritten") }
        catch { check(disk(fresh) == beforeDuplicate, "duplicate creation leaves the existing file unchanged") }
        do { try store.createTeXFile(named: "../escape", in: chapters); fatalError("path escaped") }
        catch { check(!fm.fileExists(atPath: directory.appendingPathComponent("escape.tex").path), "file names cannot select another directory") }

        store.beginSidebarCreation(folder: false, in: chapters)
        let pendingName = store.sidebarNameEdit!
        let defaultFile = chapters.appendingPathComponent(pendingName.defaultName)
        check(!fm.fileExists(atPath: defaultFile.path), "new file naming starts with a sidebar placeholder without writing partial names")
        let virtualParent = NavigationNode(id: "parent", title: "chapters", kind: .folder, url: chapters)
        check(store.sidebarChildren(of: virtualParent).contains { $0.id == pendingName.placeholderID }, "the naming placeholder appears in its target folder")
        store.updateSidebarName(".tex", id: pendingName.id)
        check(store.commitSidebarNameEdit() && fm.fileExists(atPath: defaultFile.path), "an empty file stem accepts the default name")
        check(disk(defaultFile).hasPrefix("% !TeX root = ../main.tex"), "default-named files retain the correct main-file comment")
        store.beginSidebarCreation(folder: false, in: chapters)
        let nextName = store.sidebarNameEdit!
        check(nextName.defaultName != pendingName.defaultName, "new placeholders choose an unused numbered default name")
        store.updateSidebarName("fresh.tex", id: nextName.id)
        check(!store.commitSidebarNameEdit() && store.sidebarNameEdit?.error != nil && disk(fresh) == beforeDuplicate, "inline name collisions keep editing and preserve the existing file")
        store.cancelSidebarNameEdit(id: nextName.id)
        check(store.sidebarNameEdit == nil && !fm.fileExists(atPath: chapters.appendingPathComponent(nextName.defaultName).path), "cancelling an uncommitted placeholder creates no file")
        store.beginSidebarRename(defaultFile)
        let renameName = store.sidebarNameEdit!
        store.updateSidebarName("inline-renamed", id: renameName.id)
        check(store.commitSidebarNameEdit() && !fm.fileExists(atPath: defaultFile.path)
            && fm.fileExists(atPath: chapters.appendingPathComponent("inline-renamed.tex").path), "row renaming commits through the safe file rename workflow")
        check(oldMain.text.contains("\\input{chapters/inline-renamed.tex}"), "row renaming updates the unsaved main-file reference")
        store.beginSidebarCreation(folder: true, in: chapters)
        let folderName = store.sidebarNameEdit!
        store.updateSidebarName("", id: folderName.id)
        check(store.commitSidebarNameEdit() && fm.fileExists(atPath: chapters.appendingPathComponent(folderName.defaultName).path), "blank new-folder names commit the default folder name")

        oldMain.text += "\nUnsaved body\n"
        let diskBody = disk(root)
        do { try store.selectMainFile(fresh); fatalError("main file changed") }
        catch { check(store.root == root, "a nested subfile cannot become the main file") }
        check(disk(fresh).hasPrefix("% !TeX root = ../main.tex"), "rejected nested main changes do not rewrite root comments")
        check(oldMain.isDirty && oldMain.text.contains("Unsaved body") && !disk(root).contains("Unsaved body"), "main-file locking preserves unsaved body text")
        check(disk(root).contains("Body") && diskBody.contains("Body"), "saved body text remains unchanged")
        do { try store.selectMainFile(stale); fatalError("sibling became the main file") }
        catch { check(store.root == root, "a root-directory sibling cannot replace the fixed main file") }
        let currentMain = oldMain
        check(disk(root).hasPrefix("% !TeX root = main.tex") && disk(child).hasPrefix("% !TeX root = ../main.tex"), "rejected main changes preserve all root comments")
        check(oldMain.isDirty && oldMain.text.contains("Unsaved body") && !disk(root).contains("Unsaved body"), "main locking preserves unsaved body edits")
        let renamedSubfile = try store.renameProjectFile(fresh, to: "renamed")
        check(store.root == root && store.documents.contains { $0.url == renamedSubfile }, "renaming a subfile keeps the main file fixed")
        check(oldMain.text.contains("\\input{chapters/renamed.tex}") && !oldMain.text.contains("\\input{chapters/fresh.tex}"), "literal input references follow a renamed file in unsaved buffers")
        let renamedMain = try store.renameProjectFile(root, to: "renamed-main")
        check(store.root == renamedMain && currentMain.url == renamedMain, "renaming the same main file preserves its document identity")
        check(disk(renamedMain).hasPrefix("% !TeX root = renamed-main.tex") && disk(child).hasPrefix("% !TeX root = ../renamed-main.tex"), "main-file rename updates relative root comments throughout the project")
        let renamedChild = try store.renameProjectFile(child, to: "child renamed.tex")
        check(fm.fileExists(atPath: renamedChild.path) && !fm.fileExists(atPath: child.path), "inactive files can be renamed without opening them")
        do { try store.renameProjectFile(renamedChild, to: "renamed.tex"); fatalError("rename overwrote target") }
        catch { check(fm.fileExists(atPath: renamedChild.path) && fm.fileExists(atPath: renamedSubfile.path), "rename collisions preserve both files") }
        let references = "\\input{chapters/child} % \\input{chapters/child}\n\\begin{verbatim}\\input{chapters/child}\\end{verbatim}"
        let updatedReferences = ProjectStore.updatingFileReferences(in: references, owner: root, from: child, to: renamedChild)
        check(updatedReferences.hasPrefix("\\input{chapters/child renamed} % \\input{chapters/child}"), "reference updates preserve omitted extensions and ignore comments")
        check(updatedReferences.hasSuffix("\\begin{verbatim}\\input{chapters/child}\\end{verbatim}"), "literal source examples are not renamed")

        let trash = base.appendingPathComponent("TestTrash", isDirectory: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        store.openSource(renamedChild)
        store.moveFileToTrash = { file in try fm.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent)) }
        check(try! store.trashProjectFile(renamedChild), "file deletion uses the trash operation")
        check(fm.fileExists(atPath: trash.appendingPathComponent(renamedChild.lastPathComponent).path) && !fm.fileExists(atPath: renamedChild.path), "trash retains recoverable file contents")
        check(!store.documents.contains { $0.url == renamedChild } && store.activeDocument?.url == renamedMain, "deleting an active subfile falls back to the pinned main file")
        check(store.saveAll(), "remaining edits can be saved after metadata changes")
        store.moveFileToTrash = { _ in throw ProjectError.message("Simulated trash failure") }
        do { try store.trashProjectFile(renamedMain); fatalError("trash failure ignored") }
        catch { check(store.root == renamedMain && fm.fileExists(atPath: renamedMain.path), "failed trash operations leave the workspace intact") }
        store.moveFileToTrash = { file in try fm.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent)) }
        check(try! store.trashProjectFile(renamedMain), "main-file deletion is supported after edits are resolved")
        check(store.root == nil && store.documents.isEmpty, "deleting the main file returns to the document entry screen")
        print("PASS: \(checks) sidebar-file assertions")
    }
}
