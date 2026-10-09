import AppKit
import Foundation

@main
struct EditorBehaviorTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let previousMainFileSetting = BuildSettings.shared.requireMainFile
        BuildSettings.shared.requireMainFile = false
        defer { BuildSettings.shared.requireMainFile = previousMainFileSetting }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("main.tex")
        let child = directory.appendingPathComponent("中文 空格.tex")
        let initial = "\\documentclass{article}\r\n\\begin{document}\r\nOriginal\r\n\\end{document}\r\n"
        try initial.write(to: root, atomically: true, encoding: .utf8)
        try "% !TeX root = main.tex\n\\section{Child}\n".write(to: child, atomically: true, encoding: .utf8)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }; checks += 1
        }
        let store = ProjectStore(library: DocumentLibrary(directory: directory.appendingPathComponent("Library"), bundledTemplatesDirectory: URL(fileURLWithPath: "QuillTeX/Project/BundledTemplates")))
        let visibility = ProjectStore(library: store.library)
        visibility.documents = [SourceDocument(url: root, text: "")]
        check(!visibility.isTabBarVisible, "one file hides tabs by default")
        visibility.documents.append(SourceDocument(url: child, text: ""))
        check(visibility.isTabBarVisible, "multiple files show tabs by default")
        visibility.toggleTabBar()
        visibility.documents.append(SourceDocument(url: directory.appendingPathComponent("another.tex"), text: ""))
        visibility.activeID = visibility.documents.last?.id
        check(!visibility.isTabBarVisible, "manual hide survives opening and switching files")
        visibility.setTabBarVisible(true)
        visibility.documents.removeLast(2)
        check(visibility.isTabBarVisible, "manual show survives closing to one file")
        check(!ProjectStore(library: store.library).isTabBarVisible, "new workspace has its own default")

        store.openProject(child, explicitRoot: true)
        check(store.root == child && store.activeDocument?.url == child, "explicit open uses the selected file despite its root directive")
        check(store.documents.count == 1, "explicit open does not substitute neighboring main.tex")
        check(store.expectedPDF?.lastPathComponent == "中文 空格.pdf", "explicit main determines the PDF name")
        let standalone = directory.appendingPathComponent("standalone.tex")
        try "Just text\n".write(to: standalone, atomically: true, encoding: .utf8)
        store.openProject(standalone, explicitRoot: true)
        check(store.root == standalone, "explicit open requires no documentclass or main-file chooser")
        store.openProject(child)
        check(store.root == root, "root directive resolves main")
        check(store.documents.count == 2 && store.documents.first?.url == root, "root tab pinned first")
        check(store.activeDocument?.url == child, "standalone child open activates the child")
        let switching = ProjectStore(library: store.library)
        switching.openProject(standalone)
        check(switching.root == standalone, "no directive never substitutes a neighboring main.tex")
        BuildSettings.shared.requireMainFile = true
        switching.openProject(standalone)
        check(switching.root == standalone, "legacy opening preference cannot block arbitrary tex files")
        let nested = directory.appendingPathComponent("root-switch", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedMain = nested.appendingPathComponent("chapter.tex")
        try "Chapter only".write(to: nestedMain, atomically: true, encoding: .utf8)
        let oldMain = switching.activeDocument!
        oldMain.text += "unsaved"
        oldMain.selection = NSRange(location: 3, length: 0)
        switching.openSource(nestedMain)
        let promoted = switching.activeDocument!
        promoted.text += "buffer"
        try switching.selectMainFile(nestedMain)
        check(switching.root == nestedMain && switching.directory == nested, "promotion changes compile root and Folder directory")
        check(switching.documents.first === promoted && switching.documents.count == 2, "new main reuses its existing buffer and becomes the pinned first tab")
        check(switching.documents.contains { $0 === oldMain && $0.isDirty && $0.selection.location == 3 }, "old main retains unsaved text and selection")
        check(promoted.text == "Chapter onlybuffer", "promotion preserves the new main's unsaved buffer")
        check(switching.expectedPDF?.lastPathComponent == "chapter.pdf", "new main replaces preview output name")
        switching.close(promoted)
        check(switching.documents.count == 2, "new main is unclosable")
        try switching.selectMainFile(standalone)
        check(switching.documents.first === oldMain && switching.documents.count == 2, "switching back reuses old main without duplicate tabs")
        promoted.savedText = promoted.text
        switching.close(promoted)
        check(switching.documents.count == 1, "former main becomes closable")
        let missing = directory.appendingPathComponent("missing-root.tex")
        try "% !TeX root = absent.tex\nChild".write(to: missing, atomically: true, encoding: .utf8)
        let missingResolution = try ProjectStore.resolveMainFile(missing)
        check(missingResolution.url == missing && missingResolution.warning != nil, "missing directive falls back to the opened file with a warning")
        let loop = directory.appendingPathComponent("loop.tex")
        let loopChild = directory.appendingPathComponent("loop-child.tex")
        try "% !TeX root = loop-child.tex".write(to: loop, atomically: true, encoding: .utf8)
        try "% !TeX root = loop.tex".write(to: loopChild, atomically: true, encoding: .utf8)
        let loopResolution = try ProjectStore.resolveMainFile(loop)
        check(loopResolution.url == loop && loopResolution.warning != nil, "directive cycle safely falls back")
        try "% !TeX root = chapter.tex".write(to: nestedMain, atomically: true, encoding: .utf8)
        let selfResolution = try ProjectStore.resolveMainFile(nestedMain)
        check(selfResolution.url == nestedMain && selfResolution.warning == nil, "self root is valid")
        let nestedChild = nested.appendingPathComponent("child.tex")
        try "% !TeX root = ../main.tex".write(to: nestedChild, atomically: true, encoding: .utf8)
        let relativeResolution = try ProjectStore.resolveMainFile(nestedChild)
        check(relativeResolution.url == root, "nested relative directive resolves against child directory")
        let beforeFailure = switching.root
        do { try switching.selectMainFile(directory.appendingPathComponent("absent.tex")); fatalError("missing main accepted") } catch {}
        check(switching.root == beforeFailure && switching.documents.first === oldMain, "failed main switch leaves the project and buffers intact")
        let dummyPDF = directory.appendingPathComponent("old.pdf")
        try Data("old preview".utf8).write(to: dummyPDF)
        switching.build.adoptExistingPDF(dummyPDF)
        try switching.selectMainFile(nestedMain)
        check(switching.build.pdfURL == nil && switching.build.diagnostics.isEmpty, "main switch clears the previous preview and diagnostics")
        BuildSettings.shared.requireMainFile = false
        store.openSource(root)
        let doc = store.activeDocument!
        let surface = EditorSurface(document: doc, store: store)
        doc.editorSurface = surface
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.makeFirstResponder(surface.textView)
        let originalRange = (initial as NSString).range(of: "Original")
        surface.textView.setSelectedRange(originalRange)
        surface.textView.insertText("中文 😀", replacementRange: originalRange)
        check(doc.text.contains("中文 😀"), "native insertion updates model")
        check(doc.isDirty, "native edit marks document dirty")
        let edited = doc.text
        BuildSettings.shared.requireMainFile = true
        store.navigate(NavigationNode(id: "child", title: child.lastPathComponent, kind: .source, url: child))
        check(store.root == root && store.activeDocument?.url == child, "main-file restriction still allows sidebar child editing without changing the root")
        BuildSettings.shared.requireMainFile = false
        let separateDocument = store.activeDocument!
        let separateSurface = EditorSurface(document: separateDocument, store: store)
        separateDocument.editorSurface = separateSurface
        let childOriginal = separateDocument.text
        separateSurface.textView.insertText("independent", replacementRange: NSRange(location: 0, length: 0))
        check(surface.textView.undoManager !== separateSurface.textView.undoManager, "each document owns an independent undo stack")
        store.openSource(root)
        check(store.activeDocument === doc, "tab switches reuse document")
        check(doc.editorSurface === surface, "tab switches retain native text storage and undo manager")
        surface.textView.undoManager?.undo()
        check(doc.text == initial, "undo after tab switch restores source")
        check(separateDocument.text.hasPrefix("independent"), "root undo does not undo child edits")
        separateSurface.textView.undoManager?.undo()
        check(separateDocument.text == childOriginal, "child undo restores its own source")
        surface.textView.undoManager?.redo()
        check(doc.text == edited, "redo after tab switch")
        surface.textView.setSelectedRange(NSRange(location: (doc.text as NSString).length, length: 0))
        surface.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(doc.text.hasSuffix("\r\n\r\n"), "Return preserves CRLF")
        let beforeComposition = surface.textView.string
        surface.textView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(surface.textView.hasMarkedText(), "NSTextView retains marked composition")
        surface.textView.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(!surface.textView.hasMarkedText(), "composition commits normally")
        check(doc.text == beforeComposition + "中", "composition replaces marked candidate without duplicating text")
        // The ruler marks the line holding the insertion point.
        surface.layoutSubtreeIfNeeded()
        let rulerText = surface.textView.string as NSString
        func lineStart(_ line: Int) -> Int {
            var position = 0
            for _ in 1..<line { position = NSMaxRange(rulerText.lineRange(for: NSRange(location: position, length: 0))) }
            return position
        }
        surface.textView.setSelectedRange(NSRange(location: lineStart(3), length: 0))
        check((surface.verticalRulerView as? LineNumberRuler)?.currentLine == 3, "ruler marks the caret's line")
        // Mid-line offsets must not be rounded up to the next line.
        surface.textView.setSelectedRange(NSRange(location: lineStart(3) + 3, length: 0))
        check((surface.verticalRulerView as? LineNumberRuler)?.currentLine == 3, "mid-line caret keeps its own line")
        surface.textView.setSelectedRange(NSRange(location: lineStart(4) + 1, length: 0))
        check((surface.verticalRulerView as? LineNumberRuler)?.currentLine == 4, "ruler follows the caret down")
        surface.textView.setSelectedRange(NSRange(location: lineStart(1), length: 0))
        check((surface.verticalRulerView as? LineNumberRuler)?.currentLine == 1, "ruler follows the caret up")
        check(surface.lineNumber(atCharacter: lineStart(3)) == 3, "caret offset resolves to its line number")
        check(surface.lineNumber(atCharacter: lineStart(3) + 3) == 3, "mid-line offset resolves to its own line")
        // Output defaults to the main file's own folder, and a relative value nests.
        check(store.buildOutputDirectory.standardizedFileURL == directory.standardizedFileURL, "output defaults to the project folder")
        check(store.expectedPDF?.lastPathComponent == "main.pdf", "expected PDF sits next to the main file")
        let previousOutput = BuildSettings.shared.outputDirectory
        BuildSettings.shared.outputDirectory = "out"
        check(store.buildOutputDirectory.standardizedFileURL == directory.appendingPathComponent("out").standardizedFileURL, "relative output nests inside the project")
        BuildSettings.shared.outputDirectory = "/tmp/quilltex-absolute-out"
        check(store.buildOutputDirectory.path == "/tmp/quilltex-absolute-out", "absolute output is used as is")
        BuildSettings.shared.outputDirectory = previousOutput
        // MARK: LaTeX scanning

        let sample = """
        \\section{引言} % 注释里的 \\% 不是注释
        \\begin{equation}
          E = mc^2 \\label{eq:emc}
        \\end{equation}
        \\ref{eq:emc} 与 \\cite{knuth84}
        \\begin{verbatim}
          \\section{不是代码} % 也不是注释
        \\end{verbatim}
        \\verb|%| 和一个孤立的 } 括号
        """
        let spans = LaTeXHighlighter.spans(in: sample)
        let ns = sample as NSString
        func token(at needle: String, occurrence: Int = 0) -> LaTeXHighlighter.Token? {
            var seen = 0
            for span in spans where ns.substring(with: span.range) == needle {
                if seen == occurrence { return span.token }
                seen += 1
            }
            return nil
        }
        check(token(at: "\\section") == .command, "a command is a command")
        check(token(at: "equation", occurrence: 0) == .environment, "environment names are recognised")
        check(token(at: "eq:emc", occurrence: 0) == .key, "label arguments are keys")
        check(token(at: "eq:emc", occurrence: 1) == .key, "reference arguments are keys")
        check(token(at: "knuth84") == .key, "citation keys are keys")
        check(spans.contains { $0.token == .comment && ns.substring(with: $0.range).contains("注释里的") },
              "a comment runs to the end of the line")
        check(!spans.contains { $0.token == .comment && ns.substring(with: $0.range).hasPrefix("% 不是注释") },
              "an escaped percent does not start a comment")
        check(spans.contains { $0.token == .verbatim && ns.substring(with: $0.range).contains("不是代码") },
              "verbatim bodies are literal, comments and commands included")
        check(spans.contains { $0.token == .verbatim && ns.substring(with: $0.range).contains("%") },
              "\\verb switches to a literal run")
        check(spans.contains { $0.token == .unmatchedBrace }, "a closing brace with nothing open is flagged")
        check(spans.contains { $0.token == .mathBody && ns.substring(with: $0.range).contains("E = mc^2") },
              "an equation body is mathematics")

        // MARK: Completion

        func suggestion(_ text: String) -> LaTeXCompletion.Suggestion? {
            LaTeXCompletion.suggestion(in: text, at: (text as NSString).length)
        }
        check(suggestion("\\sec")?.context == .command, "a backslash starts a command")
        check(suggestion("\\begin{it")?.context == .environment, "\\begin{ completes environments")
        check(suggestion("\\ref{fi")?.context == .label, "\\ref{ completes labels")
        check(suggestion("\\cite[p. 3]{kn")?.context == .citation, "\\cite with an optional argument completes keys")
        check(suggestion("plain words") == nil, "ordinary prose is left alone")
        let commandSuggestion = suggestion("\\fra")!
        check(LaTeXCompletion.candidates(for: commandSuggestion, labels: [], citations: []).first == "\\frac",
              "prefix matches come first")
        let labelSuggestion = suggestion("\\ref{wa")!
        check(LaTeXCompletion.candidates(for: labelSuggestion, labels: ["wave_function", "gronwall"], citations: []).first == "wave_function",
              "labels come from the project")
        let environmentSuggestion = suggestion("\\begin{ite")!
        let expansion = LaTeXCompletion.expansion(for: "itemize", context: environmentSuggestion.context)
        check(expansion?.text == "itemize}\n\n\\end{itemize}", "an environment closes itself")
        check(LaTeXCompletion.expansion(for: "frac", context: .command) == nil, "commands are inserted as they are")

        // Inline hint: the missing tail of an unambiguous candidate.
        let inline = LaTeXCompletion.inline(in: "\\sect", at: 5, labels: [], citations: [])
        check(inline?.full == "\\section", "the inline hint names the whole candidate")
        check(inline?.remainder == "ion", "the inline hint only carries the missing tail")
        check(LaTeXCompletion.inline(in: "\\s", at: 2, labels: [], citations: []) == nil,
              "a single letter after a backslash offers no hint")
        check(LaTeXCompletion.inline(in: "\\zzz", at: 4, labels: [], citations: []) == nil,
              "no candidate means no hint")
        check(LaTeXCompletion.inline(in: "\\begin{equ", at: 10, labels: [], citations: [])?.remainder == "ation",
              "environments hint too")
        check(LaTeXCompletion.inline(in: "\\ref{wave", at: 9, labels: ["wave_function"], citations: [])?.remainder == "_function",
              "labels hint from the project")

        // The candidate box is as wide as its longest row, within bounds.
        let narrow = LaTeXCompletion.panelWidth(for: [.init(title: "\\frac")])
        let wide = LaTeXCompletion.panelWidth(for: [.init(title: "\\DeclareMathOperatorWithAVeryLongName")])
        check(wide > narrow, "a longer candidate makes a wider panel")
        check(narrow >= 196, "the panel keeps a comfortable floor")
        check(LaTeXCompletion.panelWidth(for: [.init(title: "\\" + String(repeating: "x", count: 120))]) <= 440,
              "a very long name cannot stretch the panel past its cap")

        // Citation keys come out of .bib files.
        check(ProjectIndexer.citationKeys(in: "@article{knuth84,\n  title={Literate Programming}\n}\n@book{lamport94}") == ["knuth84", "lamport94"],
              "bib keys are parsed in order")

        // The line-number gutter is sized by the largest line number.
        check(LineNumberRuler.thickness(forLineCount: 9) == LineNumberRuler.thickness(forLineCount: 13), "one and two digit files share a gutter")
        check(LineNumberRuler.thickness(forLineCount: 999) == LineNumberRuler.thickness(forLineCount: 100), "three digit files share a gutter")
        check(LineNumberRuler.thickness(forLineCount: 1200) > LineNumberRuler.thickness(forLineCount: 90), "a four digit file needs a wider gutter")
        check(LineNumberRuler.thickness(forLineCount: 13) < 40, "a short document keeps a narrow gutter")
        check(store.save(doc), "atomic save succeeds")
        let disk = try String(contentsOf: root, encoding: .utf8)
        check(disk == doc.text, "disk roundtrip")
        check(!doc.isDirty, "save clears dirty state")
        store.openSource(child)
        let childDoc = store.activeDocument!
        store.close(childDoc)
        check(store.documents.count == 1 && store.activeDocument === doc, "closing child falls back to root")
        store.close(doc)
        check(store.documents.count == 1, "root tab cannot close")
        check(store.creationDirectory?.standardizedFileURL == directory.standardizedFileURL, "creation defaults to the project root")
        let chapters = try store.createFolder(named: "chapters", in: directory)
        let subfolder = try store.createFolder(named: "中文 文件夹", in: chapters)
        store.sidebarMode = .folder; store.selectedFolder = subfolder
        check(store.creationDirectory?.standardizedFileURL == subfolder.standardizedFileURL, "folder selection determines the creation location")
        store.sidebarMode = .subfiles
        check(store.creationDirectory?.standardizedFileURL == directory.standardizedFileURL, "Subfiles creation starts at the project root")
        do { try store.createFolder(named: "中文 文件夹", in: chapters); fatalError("existing folder was recreated") }
        catch { check(FileManager.default.fileExists(atPath: subfolder.path), "folder creation does not replace an existing folder") }
        do { try store.createFolder(named: "../escape", in: directory); fatalError("folder path traversal was allowed") }
        catch { check(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape").path), "new folder names cannot escape the project") }
        let newChild = subfolder.appendingPathComponent("new.tex")
        // The harness runs in one event; close previous typing groups to model
        // opening the save panel in a separate user action.
        if let undo = surface.textView.undoManager {
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        let beforeCreate = doc.text
        let diskBeforeCreate = try String(contentsOf: root, encoding: .utf8)
        try store.createSubfile(at: newChild)
        check(store.root == root && store.activeDocument?.url == newChild, "new subfile opens inside the existing project")
        check(try! String(contentsOf: newChild, encoding: .utf8) == "% !TeX root = ../../main.tex\r\n\r\n", "nested subfile points to the main file and preserves line endings")
        check(doc.text.contains("\\input{chapters/中文 文件夹/new.tex}\r\n\\end{document}"), "new subfile is linked before end document")
        check(try! String(contentsOf: root, encoding: .utf8) == diskBeforeCreate, "creating a subfile preserves unsaved main-file changes")
        let createdIndex = ProjectIndexer(root: root, overrides: [root: doc.text]).build()
        check(createdIndex.subfiles.contains { $0.url == newChild }, "created subfile appears in Subfiles")
        let linkedText = doc.text
        do { try store.createSubfile(at: newChild); fatalError("overwriting an existing file was allowed") }
        catch { check(doc.text == linkedText, "existing subfile is not overwritten or linked twice") }
        do { try store.createSubfile(at: directory.deletingLastPathComponent().appendingPathComponent("outside.tex")); fatalError("outside project creation was allowed") }
        catch { check(doc.text == linkedText, "out-of-project creation leaves the main file alone") }
        surface.textView.undoManager?.undo()
        check(doc.text == beforeCreate, "inserting the new subfile reference can be undone")
        store.openSource(root)
        let renamed = directory.appendingPathComponent("renamed.tex")
        doc.text += "\n% Unsaved rename test\n"
        let unsavedBeforeRename = doc.text
        try store.updateActiveFile(renamed, tags: ["Research"])
        check(store.root == renamed && doc.url == renamed, "rename updates root and existing buffer URL")
        check(doc.text == unsavedBeforeRename && doc.isDirty, "rename preserves unsaved edits")
        check(!FileManager.default.fileExists(atPath: root.path), "rename moves the disk file")
        check((try! renamed.resourceValues(forKeys: [.tagNamesKey])).tagNames == ["Research"], "Finder tags persist")
        do { try store.updateActiveFile(newChild, tags: []); fatalError("existing file overwritten") }
        catch { check(doc.url == renamed && FileManager.default.fileExists(atPath: renamed.path), "failed move preserves current path") }
        let moved = subfolder.appendingPathComponent("renamed.tex")
        try store.updateActiveFile(moved, tags: ["Research"])
        check(store.root == moved && doc.url == moved, "folder change updates save location")
        check(store.save(doc), "renamed buffer saves to its new location")
        check(try! String(contentsOf: moved, encoding: .utf8) == unsavedBeforeRename, "new path contains current edits")
        print("PASS: \(checks) editor and document assertions")
    }
}
