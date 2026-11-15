import AppKit

@main
struct TeXProjectTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tex-project-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("main.tex")
        let linked = directory.appendingPathComponent("linked.tex")
        let other = directory.appendingPathComponent("other.tex")
        let nestedDirectory = directory.appendingPathComponent("chapters")
        let nested = nestedDirectory.appendingPathComponent("nested.tex")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try "\\documentclass{article}\n\\begin{document}\n\\end{document}\n".write(to: root, atomically: true, encoding: .utf8)
        try "% !TeX root = main.tex\nLinked\n".write(to: linked, atomically: true, encoding: .utf8)
        try "Other\n".write(to: other, atomically: true, encoding: .utf8)
        try "% !TeX root = ../main.tex\nNested\n".write(to: nested, atomically: true, encoding: .utf8)

        let plugin = PluginManager.shared
        let previousEnabled = plugin.isEnabled(PluginManager.texProjectID)
        let previousSetting = UserDefaults.standard.object(forKey: "plugins.subfiles.enabled")
        defer {
            plugin.setEnabled(previousEnabled, for: PluginManager.texProjectID)
            if previousSetting == nil { UserDefaults.standard.removeObject(forKey: "plugins.subfiles.enabled") }
        }
        plugin.setEnabled(true, for: PluginManager.texProjectID)

        let store = ProjectStore(library: DocumentLibrary(directory: directory.appendingPathComponent("Library")),
                                 maintainsRootDirectives: false)
        store.openProject(root, explicitRoot: true)
        store.index = ProjectIndexer(root: root, overrides: [:]).build()
        defer { store.finishClosing() }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }

        check(store.mainTeXFiles == [root], "Main contains only the compile target")
        check(Set(store.subTeXFiles) == Set([linked, nested]), "Sub is derived from TeX root comments")
        check(store.otherTeXFiles == [other], "Others contains TeX files without the current root comment")

        try store.setTeXFile(other, role: .sub)
        check(store.subTeXFiles.contains(other), "moving to Sub adds a root comment immediately")
        check(store.activeDocument?.text.hasPrefix("% !TeX root = main.tex\n") == true,
              "the added root comment uses a relative path")
        try store.setTeXFile(other, role: .other)
        check(store.otherTeXFiles.contains(other), "moving to Others removes the root relationship")
        check(ProjectIndexer.rootDirective(in: store.activeDocument!.text) == nil,
              "moving to Others removes the root comment from the buffer")

        let crlf = "\u{FEFF}% !TeX root = main.tex\r\nBody\r\n"
        check(ProjectStore.removingRootDirectives(from: crlf) == "\u{FEFF}Body\r\n",
              "comment removal preserves BOM and CRLF content")
        let literal = "\\begin{verbatim}\n% !TeX root = fake.tex\n\\end{verbatim}\n"
        check(ProjectStore.removingRootDirectives(from: literal) == literal,
              "root-looking text in a verbatim block is left alone")

        store.sidebarMode = .tex
        check(store.texProjectEnabled && store.sidebarMode == .tex,
              "TeX Project is native and keeps its sidebar mode")

        let standalone = directory.appendingPathComponent("standalone.tex")
        try "Standalone\n".write(to: standalone, atomically: true, encoding: .utf8)
        let plainStore = ProjectStore(library: store.library, maintainsRootDirectives: false)
        plainStore.openProject(root, explicitRoot: true)
        plainStore.openSource(standalone)
        check(plainStore.root == root && plainStore.activeDocument?.url == standalone,
              "native project keeps the main file while editing an unlinked source")
        plainStore.openProject(linked)
        check(plainStore.root == root && plainStore.activeDocument?.url == linked,
              "native project resolves a root directive to its declared target")
        plainStore.finishClosing()

        print("PASS: \(checks) TeX-project assertions")
    }
}
