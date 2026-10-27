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
        let store = ProjectStore(library: DocumentLibrary(directory: directory.appendingPathComponent("Library"), bundledTemplatesDirectory: URL(fileURLWithPath: "QuillTeX/Project/bundled_templates")), maintainsRootDirectives: false)
        let visibility = ProjectStore(library: store.library, maintainsRootDirectives: false)
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
        check(!ProjectStore(library: store.library, maintainsRootDirectives: false).isTabBarVisible, "new workspace has its own default")

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
        let switching = ProjectStore(library: store.library, maintainsRootDirectives: false)
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
        do { try switching.selectMainFile(nestedMain); fatalError("main file changed") }
        catch { check(switching.root == standalone, "main-file selection stays fixed after opening a workspace") }
        check(switching.documents.first === oldMain && switching.documents.count == 2, "a rejected main change preserves tab order")
        check(oldMain.isDirty && oldMain.selection.location == 3 && promoted.text == "Chapter onlybuffer", "a rejected main change preserves both edited buffers")
        check(switching.expectedPDF?.lastPathComponent == standalone.deletingPathExtension().lastPathComponent + ".pdf", "a rejected main change preserves the compile target")
        promoted.savedText = promoted.text
        switching.close(promoted)
        check(switching.documents.count == 1, "ordinary subfiles remain closable")
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
        do { try switching.selectMainFile(nestedMain); fatalError("main file changed") } catch {}
        check(switching.build.pdfURL == dummyPDF, "a rejected main change preserves the existing preview")
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
        var editNotifications = 0
        let editObservation = store.objectWillChange.sink { editNotifications += 1 }
        surface.textView.insertText("中文 😀", replacementRange: originalRange)
        check(editNotifications == 1, "one native edit publishes one project change")
        editObservation.cancel()
        check(doc.text.contains("中文 😀"), "native insertion updates model")
        check(doc.isDirty, "native edit marks document dirty")
        check(surface.textView.undoManager === doc.undoManager, "editor and document share the menu undo manager")
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
        var indexedText = "one\r\n中文😀\nlast\r" as NSString
        var lineCache = SourceLineIndex()
        lineCache.reset(indexedText)
        var seed: UInt64 = 12345
        func nextRandom(_ limit: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(max(1, limit)))
        }
        let replacements = ["x", "\n", "\r", "\r\n", "中文😀", "", "\u{2028}", "\u{2029}", "  "]
        for _ in 0..<300 {
            let start = nextRandom(indexedText.length + 1)
            let removed = nextRandom(min(5, indexedText.length - start) + 1)
            let replacement = replacements[nextRandom(replacements.count)]
            let changed = NSMutableString(string: indexedText)
            changed.replaceCharacters(in: NSRange(location: start, length: removed), with: replacement)
            indexedText = changed.copy() as! NSString
            lineCache.update(indexedText, editedRange: NSRange(location: start, length: replacement.utf16.count),
                             delta: replacement.utf16.count - removed)
            let sourceText = indexedText as String
            check((0...indexedText.length).allSatisfy {
                lineCache.lineNumber(at: $0) == EditorSurface.lineNumber(atCharacter: $0, in: sourceText)
            }, "incremental line numbers match Foundation after Unicode and newline edits")
        }
        let newlineView = SourceTextView()
        newlineView.string = "  first\r\n"; newlineView.setSelectedRange(NSRange(location: 7, length: 0))
        newlineView.insertNewline(nil)
        check(newlineView.string == "  first\r\n  \r\n" && newlineView.selectedRange().location == 11,
              "Return carries indentation and preserves CRLF")
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
        check(suggestion("\\ref{eq:wave_function-1")?.prefix == "eq:wave_function-1", "label punctuation stays inside the argument")
        check(suggestion("\\cite{first, second:key_2")?.prefix == "second:key_2", "multi-key completion replaces only the current key")
        check(suggestion("\\cite[see][p. 3]{kn")?.context == .citation, "citation completion skips both optional notes")
        check(suggestion("\\cref*{eq:wa")?.context == .label, "starred reference commands complete keys")
        check(suggestion("\\end{al")?.context == .endEnvironment, "closing environments are distinct from opening environments")
        check(suggestion("% \\frac") == nil, "comments do not offer completion")
        check(suggestion("% \\cite{") == nil, "empty arguments inside comments do not offer completion")
        check(suggestion("\\begin{verbatim}\n\\frac") == nil, "unfinished verbatim environments suppress completion")
        check(suggestion("\\begin{verbatim}\n\\ref{") == nil, "empty arguments in a literal environment do not offer completion")
        check(suggestion("\\begin{verbatim*}\n\\frac") == nil, "starred literal environments suppress completion")
        check(suggestion("\\verb|\\frac") == nil, "inline literal text suppresses completion")
        check(suggestion("\\\\sec") == nil, "a line break does not start a command completion")
        check(suggestion("\\verb|%| \\sec")?.context == .command, "completion resumes after a closed inline literal")
        check(suggestion("\\% \\sec")?.context == .command, "escaped percent leaves subsequent commands active")
        let commandSuggestion = suggestion("\\fra")!
        check(LaTeXCompletion.candidates(for: commandSuggestion, labels: [], citations: []).first == "\\frac",
              "prefix matches come first")
        let labelSuggestion = suggestion("\\ref{wa")!
        check(LaTeXCompletion.candidates(for: labelSuggestion, labels: ["wave_function", "gronwall"], citations: []).first == "wave_function",
              "labels come from the project")
        let environmentSuggestion = suggestion("\\begin{ite")!
        let expansion = LaTeXCompletion.insertion(for: "itemize", suggestion: environmentSuggestion, in: "\\begin{ite")
        check(expansion.text == "itemize}\n  \n\\end{itemize}", "an environment closes itself")
        check(LaTeXCompletion.candidates(for: suggestion("\\my")!, labels: [], citations: [],
              projectCommands: ["\\myNorm", "\\myNorm"]).filter { $0 == "\\myNorm" }.count == 1,
              "project macros join completion without duplicate rows")
        check(LaTeXCompletion.candidates(for: suggestion("\\begin{my")!, labels: [], citations: [],
              projectEnvironments: ["mytheorem"]).contains("mytheorem"), "project environments join completion")
        let closedEnvironmentSource = "\\begin{ite}"
        let closedEnvironmentSuggestion = LaTeXCompletion.suggestion(in: closedEnvironmentSource, at: 10)!
        let closedEnvironmentInsertion = LaTeXCompletion.insertion(for: "itemize", suggestion: closedEnvironmentSuggestion, in: closedEnvironmentSource)
        let environmentResult = NSMutableString(string: closedEnvironmentSource)
        environmentResult.replaceCharacters(in: closedEnvironmentInsertion.range, with: closedEnvironmentInsertion.text)
        check(environmentResult as String == "\\begin{itemize}\n  \n\\end{itemize}", "an existing closing brace is consumed exactly once")
        let endSource = "\\end{ali}"
        let endInsertion = LaTeXCompletion.insertion(for: "align", suggestion: LaTeXCompletion.suggestion(in: endSource, at: 8)!, in: endSource)
        check(endInsertion.text == "align}" && endInsertion.placeholders.isEmpty, "end completion never inserts an extra end block")
        let existingPair = "\\begin{ite}\nbody\n\\end{itemize}"
        let pairedInsertion = LaTeXCompletion.insertion(for: "itemize", suggestion: LaTeXCompletion.suggestion(in: existingPair, at: 10)!, in: existingPair)
        check(pairedInsertion.text == "itemize}", "completing an existing environment preserves its closing pair")
        let midKey = "\\ref{eq:wave_function}"
        let midSuggestion = LaTeXCompletion.suggestion(in: midKey, at: 10)!
        check((midKey as NSString).substring(with: midSuggestion.range) == "eq:wave_function", "mid-key completion replaces the remaining key instead of duplicating it")
        let fraction = LaTeXCompletion.insertion(for: "\\frac", suggestion: suggestion("\\fra")!, in: "\\fra")
        check(fraction.text == "\\frac{}{}" && fraction.placeholders == [NSRange(location: 6, length: 0), NSRange(location: 8, length: 0)], "fraction snippets have two empty argument ranges")
        let existingArguments = "\\fra{a}{b}"
        check(LaTeXCompletion.insertion(for: "\\frac", suggestion: LaTeXCompletion.suggestion(in: existingArguments, at: 4)!, in: existingArguments).text == "\\frac{a}{b}",
              "command completion preserves existing arguments")

        let reused = LaTeXCompletion.insertion(for: "\\frac", suggestion: LaTeXCompletion.suggestion(in: existingArguments, at: 4)!, in: existingArguments)
        check(reused.placeholders == [NSRange(location: 6, length: 1), NSRange(location: 9, length: 1)], "existing arguments remain editable snippet stops")
        let customSource = "\\myNo{v}"
        let customInsertion = LaTeXCompletion.insertion(for: "\\myNorm", suggestion: LaTeXCompletion.suggestion(in: customSource, at: 5)!, in: customSource)
        check(customInsertion.text == "\\myNorm{v}" && customInsertion.placeholders == [NSRange(location: 8, length: 1)], "custom commands also enter their existing argument instead of stopping before the brace")
        let partialArguments = "\\fra{a}"
        let partialExpansion = LaTeXCompletion.insertion(for: "\\frac", suggestion: LaTeXCompletion.suggestion(in: partialArguments, at: 4)!, in: partialArguments)
        check(partialExpansion.text == "\\frac{a}{}", "missing arguments are appended after existing ones")
        let unclosedSource = "\\fra{a\nnext line"
        let unclosedInsertion = LaTeXCompletion.insertion(for: "\\frac", suggestion: LaTeXCompletion.suggestion(in: unclosedSource, at: 4)!, in: unclosedSource)
        check(unclosedInsertion.text == "\\frac{a}{}" && unclosedInsertion.range.length == 6, "an unfinished argument is repaired without consuming the next line")
        let beginCommand = LaTeXCompletion.insertion(for: "\\begin", suggestion: suggestion("\\beg")!, in: "\\beg")
        check(beginCommand.text == "\\begin{}" && beginCommand.placeholders.first?.location == 7, "begin command parks the caret between braces")
        let refExpansion = LaTeXCompletion.insertion(for: "eq:one", suggestion: suggestion("\\ref{eq")!, in: "\\ref{eq")
        check(refExpansion.text == "eq:one}", "key completion repairs a missing closing brace")
        let nestedCompletion = "\\begin{document}\n\\begin{mytheorem}\n\\begin{proof}\n\\end{"
        let nestedEnd = suggestion(nestedCompletion)!
        check(LaTeXCompletion.candidates(for: nestedEnd, labels: [], citations: []).prefix(3) == ["proof", "mytheorem", "document"], "end candidates follow the unmatched environment stack, including custom names")
        let closedNested = "\\begin{document}\n\\begin{proof}\n\\end{proof}\n\\end{"
        check(LaTeXCompletion.candidates(for: suggestion(closedNested)!, labels: [], citations: []).first == "document", "closed environments are popped from the context")
        let ignoredBegins = "% \\begin{fake}\n\\verb|\\begin{literal}|\n\\begin{real}\n\\end{"
        check(LaTeXCompletion.candidates(for: suggestion(ignoredBegins)!, labels: [], citations: []).first == "real", "comments and literal text cannot capture end completion")
        let endCommandSource = "\\begin{proof}\n\\en"
        check(LaTeXCompletion.insertion(for: "\\end", suggestion: suggestion(endCommandSource)!, in: endCommandSource).text == "\\end{proof}", "end command completion fills the nearest open name")
        let innerSame = "\\begin{itemize}\n  \\begin{ite}\n\\end{itemize}"
        let innerOffset = (innerSame as NSString).range(of: "ite}").location + 3
        let innerExpansion = LaTeXCompletion.insertion(for: "itemize", suggestion: LaTeXCompletion.suggestion(in: innerSame, at: innerOffset)!, in: innerSame)
        check(innerExpansion.text == "itemize}", "an existing closer can finish the current nested environment")
        let futureNested = "\\begin{ite}\n\\begin{itemize}\n\\end{itemize}"
        let futureExpansion = LaTeXCompletion.insertion(for: "itemize", suggestion: LaTeXCompletion.suggestion(in: futureNested, at: 10)!, in: futureNested)
        check(futureExpansion.text.contains("\n  \n\\end{itemize}"), "a closer belonging to a later nested block does not suppress the current closing pair")
        let pairView = SourceTextView()
        pairView.isRichText = false; pairView.allowsUndo = true
        pairView.documentUndoManager.groupsByEvent = false
        func typeIntoPair(_ text: String) {
            pairView.documentUndoManager.beginUndoGrouping()
            pairView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            pairView.documentUndoManager.endUndoGrouping()
        }
        pairView.string = ""; typeIntoPair("{")
        check(pairView.string == "{" && pairView.selectedRange().location == 1, "typing an opener only writes the opener")
        check(LaTeXCompletion.delimiterHint(in: pairView.string, at: 1)?.text == "{}", "a closing delimiter is proposed without changing source")
        pairView.documentUndoManager.beginUndoGrouping()
        check(pairView.acceptInlineHint(), "Tab accepts the proposed delimiter")
        pairView.documentUndoManager.endUndoGrouping()
        check(pairView.string == "{}" && pairView.selectedRange().location == 1, "accepted delimiter leaves the caret inside")
        pairView.documentUndoManager.beginUndoGrouping()
        pairView.deleteBackward(nil)
        pairView.documentUndoManager.endUndoGrouping()
        check(pairView.string.isEmpty, "backspace removes an empty automatic pair together")
        typeIntoPair("{")
        _ = pairView.acceptInlineHint()
        typeIntoPair("中文😀"); typeIntoPair("}")
        check(pairView.string == "{中文😀}" && pairView.selectedRange().location == 6, "typing an existing closer advances past it without duplicating Unicode text")
        pairView.string = "selected"; pairView.setSelectedRange(NSRange(location: 0, length: 8))
        typeIntoPair("(")
        check(pairView.string == "(" && pairView.selectedRange() == NSRange(location: 1, length: 0), "typing an opener replaces selection without inserting a closer")
        pairView.string = "\\begin{proof}"; pairView.setSelectedRange(NSRange(location: 12, length: 0))
        pairView.documentUndoManager.removeAllActions(); typeIntoPair("}")
        check(pairView.string == "\\begin{proof}", "finishing begin does not automatically insert end")
        pairView.documentUndoManager.beginUndoGrouping()
        check(pairView.acceptInlineHint(), "Tab accepts the environment closing hint")
        pairView.documentUndoManager.endUndoGrouping()
        check(pairView.string == "\\begin{proof}\n  \n\\end{proof}" && pairView.selectedRange().location == 16, "manually finishing begin creates end and parks the caret in the body")
        pairView.documentUndoManager.undo()
        check(pairView.string == "\\begin{proof}", "the automatic closing environment is a single undoable edit")
        check(LaTeXCompletion.typingInsertion("{", range: NSRange(location: 3, length: 0), in: "% x") == nil, "pair insertion leaves comments untouched")
        let literalPair = "\\begin{verbatim}\n"
        check(LaTeXCompletion.typingInsertion("(", range: NSRange(location: literalPair.utf16.count, length: 0), in: literalPair) == nil, "pair insertion leaves literal environments untouched")
        pairView.string = ""; pairView.setSelectedRange(NSRange(location: 0, length: 0)); typeIntoPair("\\ref{eq}")
        check(pairView.string == "\\ref{eq}", "pasted source bypasses single-key pairing")
        pairView.string = "\\"; pairView.setSelectedRange(NSRange(location: 1, length: 0))
        typeIntoPair("["); _ = pairView.acceptInlineHint(); typeIntoPair("x"); typeIntoPair("\\"); typeIntoPair("]")
        check(pairView.string == "\\[x\\]" && pairView.selectedRange().location == 5, "display-math delimiter pairs can be typed through without duplicate slashes")
        pairView.string = "\\left"; pairView.setSelectedRange(NSRange(location: 5, length: 0))
        typeIntoPair("("); _ = pairView.acceptInlineHint(); typeIntoPair("x"); typeIntoPair(")")
        check(pairView.string == "\\left(x\\right)" && pairView.selectedRange().location == 14, "left delimiters get a matching right command and can be typed through")
        pairView.string = ""; pairView.setSelectedRange(NSRange(location: 0, length: 0))
        pairView.documentUndoManager.beginUndoGrouping()
        pairView.setMarkedText("{", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(pairView.string == "{" && pairView.hasMarkedText(), "input-method composition bypasses pair insertion")
        pairView.unmarkText()
        pairView.documentUndoManager.endUndoGrouping()
        let crlfBegin = "\\begin{document}\r\n  \\begin{proof}"
        let crlfCaret = crlfBegin.utf16.count - 1
        let crlfEnd = LaTeXCompletion.typingInsertion("}", range: NSRange(location: crlfCaret, length: 0), in: crlfBegin)
        check(crlfEnd?.text == "}\r\n    \r\n  \\end{proof}", "automatic environments preserve CRLF and current indentation")

        let snippetView = SourceTextView()
        snippetView.isRichText = false; snippetView.allowsUndo = true; snippetView.string = "\\fra"
        // This command-line test has no normal AppKit event boundaries. Explicit groups
        // avoid a deferred event-group close running during the later layout test.
        snippetView.documentUndoManager.groupsByEvent = false
        func insertSnippetArgument(_ text: String) {
            snippetView.breakUndoCoalescing()
            snippetView.documentUndoManager.beginUndoGrouping()
            snippetView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            snippetView.documentUndoManager.endUndoGrouping()
            snippetView.breakUndoCoalescing()
        }
        check(snippetView.insert(candidate: "\\frac", in: NSRange(location: 0, length: 4), context: .command), "native completion inserts a fraction snippet")
        check(snippetView.string == "\\frac{}{}" && snippetView.selectedRange().location == 6, "the first snippet argument receives the caret")
        insertSnippetArgument("中文😀")
        check(snippetView.advanceSnippet() && snippetView.selectedRange().location == 12, "Tab tracks UTF-16 edits when moving to the second argument")
        insertSnippetArgument("b")
        check(snippetView.advanceSnippet(backwards: true) && snippetView.selectedRange() == NSRange(location: 6, length: 4), "Shift-Tab selects the previous filled argument")
        check(snippetView.advanceSnippet() && snippetView.selectedRange() == NSRange(location: 12, length: 1), "Tab selects the next filled argument")
        check(snippetView.advanceSnippet() && snippetView.activeSnippetRange == nil && snippetView.selectedRange().location == snippetView.string.utf16.count,
              "Tab after the last argument leaves the snippet at its end")
        let originalSnippet = "\\sqr"
        snippetView.string = originalSnippet
        snippetView.documentUndoManager.removeAllActions()
        check(snippetView.insert(candidate: "\\sqrt", in: NSRange(location: 0, length: 4), context: .command), "single argument command inserts a snippet")
        snippetView.documentUndoManager.undo()
        check(snippetView.string == originalSnippet, "a completion can be undone through the document undo manager")
        snippetView.endSnippet()
        snippetView.string = "\\fra"
        _ = snippetView.insert(candidate: "\\frac", in: NSRange(location: 0, length: 4), context: .command)
        snippetView.setSelectedRange(NSRange(location: 0, length: 0)); snippetView.validateSnippetSelection()
        check(!snippetView.advanceSnippet(), "leaving a snippet restores normal Tab behavior")
        let gutterWidth = surface.verticalRulerView!.ruleThickness
        surface.updateDiagnostics([
            .init(severity: .warning, message: "Warning", file: doc.url, line: 2),
            .init(severity: .error, message: "Error", file: doc.url, line: 2),
            .init(severity: .error, message: "Other file", file: child, line: 3)
        ])
        check((surface.verticalRulerView as? LineNumberRuler)?.diagnosticLines[2] == .error, "error markers take precedence over warnings on the same line")
        check((surface.verticalRulerView as? LineNumberRuler)?.diagnosticLines[3] == nil, "the gutter only marks diagnostics from its own document")
        check(surface.verticalRulerView!.ruleThickness == gutterWidth, "diagnostic markers preserve the gutter width")
        surface.updateDiagnostics([])
        check((surface.verticalRulerView as? LineNumberRuler)?.diagnosticLines.isEmpty == true, "new diagnostic results clear old markers")

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
        let emptyEnvironment = "\\begin{}"
        let emptyEnvironmentHint = LaTeXCompletion.inline(in: emptyEnvironment, at: 7, labels: [], citations: [])!
        let emptyEnvironmentPreview = LaTeXCompletion.inlinePreview(for: emptyEnvironmentHint, in: emptyEnvironment, at: 7)!
        check(emptyEnvironmentPreview.text == "abstract}" &&
              emptyEnvironmentPreview.coveredBrace == NSRange(location: 7, length: 1),
              "an empty environment previews the complete brace argument without drawing over the existing closer")
        let partialEnvironment = "\\begin{a}"
        let partialEnvironmentHint = LaTeXCompletion.inline(in: partialEnvironment, at: 8, labels: [], citations: [])!
        check(LaTeXCompletion.inlinePreview(for: partialEnvironmentHint, in: partialEnvironment, at: 8)?.text == "bstract}",
              "typing part of an environment still previews its closing brace")
        let missingEnvironmentBrace = "\\begin{a"
        let missingEnvironmentHint = LaTeXCompletion.inline(in: missingEnvironmentBrace, at: 8, labels: [], citations: [])!
        check(LaTeXCompletion.inlinePreview(for: missingEnvironmentHint, in: missingEnvironmentBrace, at: 8) ==
              .init(text: "bstract}", coveredBrace: nil), "the preview includes a missing closer without covering source")
        let previewFractionHint = LaTeXCompletion.inline(in: "\\fra", at: 4, labels: [], citations: [])!
        check(LaTeXCompletion.inlinePreview(for: previewFractionHint, in: "\\fra", at: 4)?.text == "c{}{}",
              "command previews show the same parameter braces that acceptance will insert")
        for (formula, prefix) in [("$\\al$", "$\\al"), ("\\[\\fra\\]", "\\[\\fra"),
                                  ("\\(\\sq\\)", "\\(\\sq"), ("$\\frac{\\al}{x}+1$", "$\\frac{\\al"),
                                  ("\\begin{equation}\n\\su+1\n\\end{equation}", "\\begin{equation}\n\\su")] {
            let offset = prefix.utf16.count
            let hint = LaTeXCompletion.inline(in: formula, at: offset, labels: [], citations: [])!
            let preview = LaTeXCompletion.inlinePreview(for: hint, in: formula, at: offset)
            check(hint.inMath && preview != nil, "math completion is visible before paired delimiters and existing math source")
            check(preview?.coveredTail?.location == offset && preview?.trailingText != nil,
                  "math source is moved after the hint instead of being overpainted")
        }
        let pairedFraction = "$\\fra$"
        let pairedHint = LaTeXCompletion.inline(in: pairedFraction, at: 5, labels: [], citations: [])!
        let pairedPreview = LaTeXCompletion.inlinePreview(for: pairedHint, in: pairedFraction, at: 5)!
        check(pairedPreview.text == "c{}{}" && pairedPreview.trailingText == NSRange(location: 5, length: 1),
              "fraction hints include both argument pairs while retaining the closing dollar")
        let fullFraction = "$\\frac$"
        let fullFractionHint = LaTeXCompletion.inline(in: fullFraction, at: 6, labels: [], citations: [])!
        check(LaTeXCompletion.inlinePreview(for: fullFractionHint, in: fullFraction, at: 6)?.text == "{}{}",
              "a complete math command still offers its missing argument braces")
        let occupiedTail = "\\begin{a} remaining text"
        let occupiedHint = LaTeXCompletion.inline(in: occupiedTail, at: 8, labels: [], citations: [])!
        check(LaTeXCompletion.inlinePreview(for: occupiedHint, in: occupiedTail, at: 8) == nil,
              "a preview cannot cover following prose")
        let insideName = "\\begin{align}"
        let insideHint = LaTeXCompletion.inline(in: insideName, at: 8, labels: [], citations: [])!
        check(LaTeXCompletion.inlinePreview(for: insideHint, in: insideName, at: 8) == nil,
              "a preview cannot cover the rest of an existing environment name")
        func environmentHint(_ prefix: String) -> LaTeXCompletion.Inline? {
            LaTeXCompletion.inline(in: "\\begin{\(prefix)}", at: 7 + prefix.utf16.count, labels: [], citations: [],
                                   projectEnvironments: ["algorithmic", "analysis"])
        }
        check(environmentHint("a")?.full == "algorithmic", "matching custom environments precede built-in environments")
        check(environmentHint("al")?.full == "algorithmic" && environmentHint("ali")?.full == "align",
              "the inline suggestion follows each typed prefix and falls back to matching built-ins")
        check(LaTeXCompletion.inline(in: "\\mat", at: 4, labels: [], citations: [],
              projectCommands: ["\\mathy"])?.full == "\\mathy", "matching custom commands precede built-in commands")
        let closingProof = "\\begin{proof}\n\\end{p"
        check(LaTeXCompletion.inline(in: closingProof, at: closingProof.utf16.count, labels: [], citations: [],
              projectEnvironments: ["proposition"])?.full == "proof", "end completion still prefers the current open environment")
        check(LaTeXCompletion.inline(in: "\\pha", at: 4, labels: [], citations: []) == nil,
              "inline completion follows the prefix instead of matching letters inside unrelated names")

        let inlineView = SourceTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        inlineView.isRichText = false; inlineView.allowsUndo = true
        inlineView.documentUndoManager.groupsByEvent = false
        inlineView.string = emptyEnvironment
        let inlineWindow = NSWindow(contentRect: inlineView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        inlineWindow.contentView = inlineView
        inlineWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        inlineWindow.orderFront(nil)
        inlineWindow.makeFirstResponder(inlineView)
        inlineView.setSelectedRange(NSRange(location: 7, length: 0))
        inlineView.refreshInlineHint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        check(inlineView.string == emptyEnvironment && !inlineView.documentUndoManager.canUndo,
              "a visible preview never enters source text or undo history")
        check(inlineView.acceptInlineHint(), "Tab can accept the inline preview without a candidate list")
        check(inlineView.string == "\\begin{abstract}\n  \n\\end{abstract}" && inlineView.selectedRange().location == 19,
              "accepting the complete preview inserts one closing brace and enters the environment body")
        inlineView.string = "\\beg"; inlineView.endSnippet()
        inlineView.setSelectedRange(NSRange(location: 4, length: 0))
        inlineView.refreshInlineHint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(inlineView.acceptInlineHint() && inlineView.string == "\\begin{}",
              "an inline command completion enters its empty parameter")
        inlineView.refreshInlineHint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let inlineTab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: inlineWindow.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        inlineView.keyDown(with: inlineTab)
        check(inlineView.string == "\\begin{abstract}\n  \n\\end{abstract}" && inlineView.selectedRange().location == 19,
              "Tab accepts the environment hint before advancing out of the command snippet")
        inlineView.string = occupiedTail; inlineView.endSnippet()
        inlineView.setSelectedRange(NSRange(location: 8, length: 0))
        inlineView.refreshInlineHint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(!inlineView.acceptInlineHint() && inlineView.string == occupiedTail,
              "Tab never accepts an invisible suggestion over existing prose")
        inlineWindow.close()

        let longSource = String(repeating: "\\section{Heading}\nPlain text\n", count: 2000)
        let longDocument = SourceDocument(url: directory.appendingPathComponent("long.tex"), text: longSource)
        let longSurface = EditorSurface(document: longDocument, store: store)
        let longWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        longWindow.isReleasedWhenClosed = false
        longWindow.contentView = longSurface; longWindow.orderFront(nil)
        let longLayout = longSurface.textView.layoutManager!
        longSurface.layoutSubtreeIfNeeded()
        longSurface.textView.scrollRangeToVisible(NSRange(location: 0, length: 1))
        let colorDeadline = Date().addingTimeInterval(2)
        while longLayout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil,
              Date() < colorDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(longLayout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil,
              "visible source receives syntax colors")
        let lastHeading = (longSource as NSString).range(of: "\\section", options: .backwards).location
        longSurface.textView.scrollRangeToVisible(NSRange(location: lastHeading, length: 1))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(longLayout.temporaryAttribute(.foregroundColor, atCharacterIndex: lastHeading, effectiveRange: nil) != nil,
              "scrolling to a distant source region paints its syntax colors")
        longWindow.close()

        // Citation keys come out of .bib files.
        check(ProjectIndexer.citationKeys(in: "@article{knuth84,\n  title={Literate Programming}\n}\n@book{lamport94}") == ["knuth84", "lamport94"],
              "bib keys are parsed in order")

        // The line-number gutter is sized by the largest line number.
        check(LineNumberRuler.thickness(forLineCount: 9) == LineNumberRuler.thickness(forLineCount: 13), "one and two digit files share a gutter")
        check(LineNumberRuler.thickness(forLineCount: 999) == LineNumberRuler.thickness(forLineCount: 100), "three digit files share a gutter")
        check(LineNumberRuler.thickness(forLineCount: 1200) > LineNumberRuler.thickness(forLineCount: 90), "a four digit file needs a wider gutter")
        check(LineNumberRuler.thickness(forLineCount: 13) < 40, "a short document keeps a narrow gutter")
        let restoredDocument = SourceDocument(url: root, text: String(repeating: "A restored reading line\n", count: 160))
        restoredDocument.selection = NSRange(location: 4, length: 8)
        restoredDocument.scrollOrigin = CGPoint(x: 0, y: 350)
        restoredDocument.restoresEditorPosition = true
        let restoredSurface = EditorSurface(document: restoredDocument, store: store)
        let restoredWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        restoredWindow.contentView = restoredSurface
        restoredSurface.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(restoredSurface.textView.selectedRange() == NSRange(location: 4, length: 8), "a real editor restores the complete saved selection")
        check(abs(restoredSurface.contentView.bounds.origin.y - 350) < 1, "a real editor preserves the reading position when its selection is offscreen")
        restoredSurface.navigate(to: NSRange(location: 0, length: 0))
        check(restoredSurface.contentView.bounds.origin.y < 30, "explicit navigation can leave the restored reading position")
        let beforeFeedback = restoredSurface.textView.string
        let selectedBeforeFeedback = restoredSurface.textView.selectedRange()
        let undoBeforeFeedback = restoredDocument.undoManager.canUndo
        restoredSurface.textView.highlightSourceLine(3)
        let lineThree = (beforeFeedback as NSString).lineRange(for: NSRange(location: ProjectStore.offset(ofLine: 3, in: beforeFeedback), length: 0))
        check(restoredSurface.textView.sourceLineHighlightRange == lineThree, "inverse feedback covers the complete source line")
        let feedbackRect = restoredSurface.textView.sourceLineHighlightRect!
        check(abs(feedbackRect.width - restoredSurface.textView.bounds.width) < 1, "source feedback spans the full editor width")
        check(restoredSurface.textView.string == beforeFeedback && restoredSurface.textView.selectedRange() == selectedBeforeFeedback, "line feedback does not replace text or turn it into a selection")
        check(restoredDocument.undoManager.canUndo == undoBeforeFeedback && !restoredDocument.isDirty, "line feedback does not modify dirty state or undo history")
        let feedbackSample = NSRect(x: feedbackRect.maxX - 24, y: feedbackRect.midY - 3, width: 12, height: 6)
        func brightness() -> CGFloat {
            let bitmap = restoredSurface.textView.bitmapImageRepForCachingDisplay(in: feedbackSample)!
            restoredSurface.textView.cacheDisplay(in: feedbackSample, to: bitmap)
            let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let highlightedBrightness = brightness()
        restoredSurface.textView.clearSourceLineHighlight()
        check(brightness() > highlightedBrightness + 0.025, "the full-width gray background is actually drawn behind source text")
        restoredSurface.textView.highlightSourceLine(2)
        RunLoop.main.run(until: Date().addingTimeInterval(1.7))
        check(restoredSurface.textView.sourceLineHighlightRange == nil, "source feedback expires without leaving a permanent decoration")
        restoredSurface.textView.highlightSourceLine(2)
        restoredSurface.reloadFromDisk()
        check(restoredSurface.textView.sourceLineHighlightRange == nil, "disk reload clears obsolete source feedback")
        restoredWindow.close()
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
        store.sidebarMode = .folder; store.toggleFolder(subfolder)
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
        // Explicit saves compile only when the Manual-mode preference is enabled.
        let settings = BuildSettings.shared
        let previousMode = settings.mode
        let previousCompileOnSave = settings.compileOnSave
        let previousTeXBin = settings.texBinDirectory
        defer {
            settings.mode = previousMode
            settings.compileOnSave = previousCompileOnSave
            settings.texBinDirectory = previousTeXBin
            settings.rescan()
        }
        let fakeTools = directory.appendingPathComponent("fake-tex")
        try FileManager.default.createDirectory(at: fakeTools, withIntermediateDirectories: true)
        for name in ["latexmk", "xelatex", "pdflatex", "lualatex"] {
            let executable = fakeTools.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        settings.texBinDirectory = fakeTools.path
        settings.rescan()
        settings.mode = .manual
        settings.compileOnSave = false
        store.build.resetProject()
        store.saveActive()
        check(!store.build.status.isRunning, "manual Save remains save-only when the option is off")
        settings.compileOnSave = true
        store.saveActive()
        check(store.build.status.isRunning, "successful manual Save triggers compilation when enabled")
        store.build.cancel()
        store.saveAllFromCommand()
        check(store.build.status.isRunning, "Save All triggers compilation after saving the project")
        store.build.cancel()
        settings.mode = .auto
        store.saveActive()
        check(!store.build.status.isRunning, "AUTO Save does not duplicate its scheduled compile")
        print("PASS: \(checks) editor and document assertions")
    }
}
