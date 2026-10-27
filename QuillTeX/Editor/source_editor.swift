import AppKit
import SwiftUI

struct SourceEditor: NSViewRepresentable {
    @ObservedObject var document: SourceDocument
    let store: ProjectStore
    func makeNSView(context: Context) -> EditorSurface {
        if let existing = document.editorSurface { return existing }
        let surface = EditorSurface(document: document, store: store)
        document.editorSurface = surface
        return surface
    }
    func updateNSView(_ view: EditorSurface, context: Context) {
        // Native text storage owns live input. Never assign string from a SwiftUI render.
    }
}

@MainActor
final class EditorSurface: NSScrollView, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    let textView = SourceTextView()
    weak var source: SourceDocument?
    weak var store: ProjectStore?
    private var highlighting: Task<Void, Never>?
    private var highlightScan: Task<[LaTeXHighlighter.Span], Never>?
    private var highlightGeneration = 0
    private var initialPositionRestorePending = true
    private var changingAttributes = false
    private var lineIndex = SourceLineIndex()
    private var textRevision = 0
    private var committedRevision = 0
    /// The ruler draws the caret's line darker, so the eye keeps its place.
    func updateCurrentLine() {
        setCurrentLine(lineNumber(atCharacter: textView.selectedRange().location))
    }
    /// One-based number of the line holding a UTF-16 character offset.
    func lineNumber(atCharacter index: Int) -> Int {
        lineIndex.lineNumber(at: index)
    }

    static func lineNumber(atCharacter index: Int, in string: String) -> Int {
        let text = string as NSString
        var line = 1, position = 0
        let offset = min(max(0, index), text.length)
        let limit = text.lineRange(for: NSRange(location: offset, length: 0)).location
        while position < limit {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
            // Stop at the line that contains the offset instead of stepping past it.
            if next <= position || next > limit { break }
            position = next; line += 1
        }
        return line
    }
    private func setCurrentLine(_ line: Int?) {
        guard let ruler = verticalRulerView as? LineNumberRuler, ruler.currentLine != line else { return }
        ruler.currentLine = line
        ruler.needsDisplay = true
    }

    func updateDiagnostics(_ diagnostics: [BuildDiagnostic]) {
        guard let source, let ruler = verticalRulerView as? LineNumberRuler else { return }
        var lines: [Int: BuildDiagnostic.Severity] = [:]
        for diagnostic in diagnostics {
            guard diagnostic.file?.standardizedFileURL == source.url.standardizedFileURL,
                  let line = diagnostic.line, line > 0, diagnostic.severity != .info else { continue }
            let end = max(line, diagnostic.endLine ?? line)
            // Logs can contain invalid ranges. A bounded marker set keeps the gutter cheap.
            for number in line...min(end, line + 1000) where lines[number] != .error {
                lines[number] = diagnostic.severity
            }
        }
        ruler.diagnosticLines = lines
    }

    init(document: SourceDocument, store: ProjectStore) {
        let restoredScrollOrigin = document.scrollOrigin
        let restoresEditorPosition = document.restoresEditorPosition
        let restoredSelection = document.selection
        self.source = document; self.store = store
        super.init(frame: .zero)
        drawsBackground = true; backgroundColor = .textBackgroundColor
        hasVerticalScroller = true; hasHorizontalScroller = false; autohidesScrollers = true
        borderType = .noBorder
        // The ruler draws a hairline at its edge, and AppKit lets it bleed past the
        // scroll view, which used to draw a stray vertical line across the breadcrumb.
        clipsToBounds = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 16, height: 18)
        textView.isRichText = false; textView.importsGraphics = false
        textView.documentUndoManager = document.undoManager
        textView.allowsUndo = true; textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.inlinePredictionType = .no
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .textColor; textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .textColor
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        paragraph.defaultTabInterval = 32
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: textView.font!, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        textView.string = document.text
        textView.setAccessibilityIdentifier("sourceEditor")
        textView.setAccessibilityLabel("LaTeX source editor")
        documentView = textView
        lineIndex.reset(textView.string as NSString)
        textView.textStorage?.delegate = self
        textView.delegate = self
        textView.compositionEnded = { [weak self] in self?.compositionDidEnd() }
        textView.commandClickLine = { [weak self] line in self?.store?.syncSourceToPDF(line: line) }
        textView.completionLabels = { [weak self] in self?.store?.index.labels ?? [] }
        textView.completionCitations = { [weak self] in self?.store?.index.citations ?? [] }
        textView.completionCommands = { [weak self] in self?.store?.index.commands ?? [] }
        textView.completionEnvironments = { [weak self] in self?.store?.index.environments ?? [] }
        let ruler = LineNumberRuler(textView: textView)
        ruler.lineNumber = { [weak self] in self?.lineNumber(atCharacter: $0) ?? 1 }
        verticalRulerView = ruler
        hasVerticalRuler = true; rulersVisible = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: contentView)
        let length = document.text.utf16.count
        let location = min(max(0, restoredSelection.location), length)
        textView.setSelectedRange(NSRange(location: location, length: min(max(0, restoredSelection.length), length - location)))
        document.restoresEditorPosition = false
        highlight()
        refreshGutter()
        updateCurrentLine()
        updateDiagnostics(store.build.diagnostics)
        if let line = document.pendingHighlightedLine {
            document.pendingHighlightedLine = nil
            textView.highlightSourceLine(line)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.initialPositionRestorePending else { return }
            self.initialPositionRestorePending = false
            self.layoutSubtreeIfNeeded()
            if restoresEditorPosition {
                if let layout = self.textView.layoutManager, let container = self.textView.textContainer {
                    layout.ensureLayout(forBoundingRect: NSRect(origin: restoredScrollOrigin, size: self.contentView.bounds.size), in: container)
                }
                self.contentView.scroll(to: restoredScrollOrigin)
            } else {
                self.contentView.scroll(to: restoredScrollOrigin)
                if document.selection.location > 0 { self.textView.scrollRangeToVisible(document.selection) }
            }
            self.reflectScrolledClipView(self.contentView)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func didScroll() {
        source?.scrollOrigin = contentView.bounds.origin
        verticalRulerView?.needsDisplay = true
        store?.scheduleSessionSave()
    }
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        lineIndex.update(textStorage.string as NSString, editedRange: editedRange, delta: delta)
        textRevision += 1
        textView.sourceTextDidChange()
    }
    private func commitEditIfNeeded() {
        guard source?.hasMarkedText == false, textRevision != committedRevision, let source else { return }
        committedRevision = textRevision
        store?.edited(source)
        scheduleHighlight()
    }
    func textDidChange(_ notification: Notification) {
        guard !changingAttributes, let source else { return }
        textView.clearSourceLineHighlight()
        source.text = textView.string; source.selection = textView.selectedRange()
        source.hasMarkedText = textView.hasMarkedText()
        refreshGutter()
        updateCurrentLine()
        textView.refreshInlineHint(force: false)
        commitEditIfNeeded()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        source?.selection = textView.selectedRange()
        source?.hasMarkedText = textView.hasMarkedText()
        updateCurrentLine()
        textView.validateSnippetSelection()
        textView.refreshInlineHint(force: false)
        store?.scheduleSessionSave()
    }
    private func compositionDidEnd() {
        guard let source else { return }
        source.hasMarkedText = textView.hasMarkedText()
        if !source.hasMarkedText, textRevision != committedRevision {
            source.text = textView.string
            commitEditIfNeeded()
        }
    }
    func navigate(to range: NSRange) {
        initialPositionRestorePending = false
        textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
        source?.selection = range
        DispatchQueue.main.async { [weak self] in
            guard let self, self.store?.sidebarNameEdit == nil else { return }; self.window?.makeFirstResponder(self.textView)
        }
    }
    func reloadFromDisk() {
        guard let source, !textView.hasMarkedText() else { return }
        textView.clearSourceLineHighlight()
        let previous = contentView.bounds.origin
        let previousSelection = source.selection
        textView.string = source.text
        textView.endSnippet()
        let length = (source.text as NSString).length
        let location = min(previousSelection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(previousSelection.length, length - location)))
        textView.undoManager?.removeAllActions()
        contentView.scroll(to: previous); reflectScrolledClipView(contentView)
        highlight(); refreshGutter()
    }
    /// Line numbers are as wide as the document needs, so a short file gets a narrow
    /// gutter instead of a fixed one with a lopsided margin.
    private func refreshGutter() {
        (verticalRulerView as? LineNumberRuler)?.updateThickness(lineCount: lineIndex.count)
        verticalRulerView?.needsDisplay = true
    }
    private func scheduleHighlight() {
        highlight(after: .milliseconds(250))
    }
    private func highlight(after delay: Duration = .zero) {
        highlighting?.cancel(); highlightScan?.cancel(); highlightGeneration += 1
        guard !textView.hasMarkedText() else { return }
        let text = textView.string
        let generation = highlightGeneration, revision = textRevision
        highlighting = Task { [weak self] in
            do { if delay != .zero { try await Task.sleep(for: delay) } }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            let scan = Task.detached(priority: .userInitiated) { LaTeXHighlighter.spans(in: text) }
            self.highlightScan = scan
            let spans = await scan.value
            guard !Task.isCancelled, self.highlightGeneration == generation,
                  self.textRevision == revision, !self.textView.hasMarkedText(),
                  let layout = self.textView.layoutManager else { return }
            // Only painting touches AppKit. Scanning does not block typing or alter undo.
            let whole = NSRange(location: 0, length: text.utf16.count)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            for span in spans {
                layout.addTemporaryAttribute(.foregroundColor, value: LaTeXPalette.color(for: span), forCharacterRange: span.range)
            }
        }
    }

}

final class SourceTextView: NSTextView {
    var subfileInsertionOffset: Int? { didSet { needsDisplay = true } }
    private(set) var sourceLineHighlightRange: NSRange?
    private var sourceLineHighlightRemoval: DispatchWorkItem?
    func highlightSourceLine(_ line: Int) {
        clearSourceLineHighlight()
        guard line > 0 else { return }
        let text = string as NSString
        let offset = ProjectStore.offset(ofLine: line, in: string)
        sourceLineHighlightRange = text.lineRange(for: NSRange(location: offset, length: 0))
        // Paint the surface and feedback before the glyphs without changing text storage.
        drawsBackground = false
        needsDisplay = true
        let removal = DispatchWorkItem { [weak self] in self?.clearSourceLineHighlight() }
        sourceLineHighlightRemoval = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: removal)
    }
    func clearSourceLineHighlight() {
        sourceLineHighlightRemoval?.cancel()
        sourceLineHighlightRemoval = nil
        guard sourceLineHighlightRange != nil else { return }
        sourceLineHighlightRange = nil
        drawsBackground = true
        needsDisplay = true
        updateInsertionPointStateAndRestartTimer(true)
    }
    var sourceLineHighlightRect: NSRect? {
        guard let range = sourceLineHighlightRange, range.location <= string.utf16.count,
              range.length <= string.utf16.count - range.location,
              let layout = layoutManager, let container = textContainer else { return nil }
        layout.ensureLayout(forCharacterRange: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = glyphs.length > 0 ? layout.boundingRect(forGlyphRange: glyphs, in: container) : layout.extraLineFragmentRect
        let lineRect = rect.isEmpty ? NSRect(x: 0, y: 0, width: 0, height: layout.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 14, weight: .regular))) : rect
        return NSRect(x: 0, y: lineRect.minY + textContainerOrigin.y - 2, width: bounds.width, height: lineRect.height + 4)
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard sourceLineHighlightRange == nil else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }
    var documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
    var compositionEnded: (() -> Void)?
    /// Called with the 1-based line under a ⌘-click, for source → PDF sync.
    var commandClickLine: ((Int) -> Void)?
    /// Candidates that come from the project rather than from a fixed list.
    var completionLabels: () -> [String] = { [] }
    var completionCitations: () -> [String] = { [] }
    var completionCommands: () -> [String] = { [] }
    var completionEnvironments: () -> [String] = { [] }
    /// Faint hint drawn after the caret; Tab writes it, anything else replaces it.
    private var inlineHint: LaTeXCompletion.Inline?
    private var delimiterHint: LaTeXCompletion.Insertion?
    private var inlinePreview: LaTeXCompletion.InlinePreview?
    private var completionWork: Task<Void, Never>?
    private var completionScan: Task<CompletionResult, Never>?
    private var completionGeneration = 0
    private var completionRequest: (revision: Int, length: Int, caret: NSRange)?
    private var contentRevision = 0
    private struct CompletionResult: Sendable {
        var delimiter: LaTeXCompletion.Insertion?
        var inline: LaTeXCompletion.Inline?
        var preview: LaTeXCompletion.InlinePreview?
    }
    private struct SnippetSession {
        var ranges: [NSRange]
        var index: Int
        var finalOffset: Int
    }
    private var snippet: SnippetSession?
    private var insertingCompletion = false
    var activeSnippetRange: NSRange? { snippet.map { $0.ranges[$0.index] } }

    func endSnippet() { snippet = nil }
    func validateSnippetSelection() {
        guard let snippet else { return }
        let active = snippet.ranges[snippet.index]
        let selected = selectedRange()
        if selected.location < active.location || NSMaxRange(selected) > NSMaxRange(active) { endSnippet() }
    }

    @discardableResult
    func advanceSnippet(backwards: Bool = false) -> Bool {
        guard !hasMarkedText(), var session = snippet else { return false }
        validateSnippetSelection()
        guard snippet != nil else { return false }
        if backwards { session.index = max(0, session.index - 1) }
        else if session.index + 1 < session.ranges.count { session.index += 1 }
        else {
            snippet = nil
            setSelectedRange(NSRange(location: min(session.finalOffset, string.utf16.count), length: 0))
            return true
        }
        snippet = session
        dismissCompletions()
        setSelectedRange(session.ranges[session.index])
        return true
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if var session = snippet {
            let active = session.ranges[session.index]
            if undoManager?.isUndoing == true || undoManager?.isRedoing == true ||
                affectedCharRange.location < active.location || NSMaxRange(affectedCharRange) > NSMaxRange(active) {
                endSnippet()
            } else {
                let delta = (replacementString ?? "").utf16.count - affectedCharRange.length
                session.ranges[session.index].length += delta
                for index in session.ranges.indices where index > session.index { session.ranges[index].location += delta }
                session.finalOffset += delta
                snippet = session
            }
        }
        return true
    }
    override func unmarkText() { super.unmarkText(); compositionEnded?() }
    override func mouseDown(with event: NSEvent) {
        clearSourceLineHighlight()
        super.mouseDown(with: event)
        guard event.modifierFlags.contains(.command),
              let layout = layoutManager, let container = textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layout.characterIndex(for: inContainer, in: container,
                                          fractionOfDistanceBetweenInsertionPoints: nil)
        commandClickLine?(EditorSurface.lineNumber(atCharacter: index, in: string))
    }
    // MARK: - Inline completion

    /// Recomputes the ghost text for wherever the caret is now.
    func refreshInlineHint(force: Bool = true) {
        if force { completionRequest = nil }
        scheduleCompletions()
    }
    func sourceTextDidChange() {
        contentRevision += 1
        dismissCompletions()
    }
    override func didChangeText() {
        contentRevision += 1
        super.didChangeText()
    }

    private func scheduleCompletions() {
        guard !hasMarkedText(), selectedRange().length == 0, window?.firstResponder === self else {
            dismissCompletions()
            return
        }
        let text = string, caret = selectedRange()
        if let previous = completionRequest, previous.caret == caret, previous.revision == contentRevision, previous.length == (text as NSString).length { return }
        completionWork?.cancel(); completionScan?.cancel(); completionGeneration += 1
        completionRequest = (contentRevision, (text as NSString).length, caret)
        let generation = completionGeneration, revision = contentRevision
        let labels = completionLabels(), citations = completionCitations()
        let commands = completionCommands(), environments = completionEnvironments()
        if inlineHint != nil || inlinePreview != nil || delimiterHint != nil { inlineHint = nil; delimiterHint = nil; inlinePreview = nil; needsDisplay = true }
        completionWork = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(65)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            let scan = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return CompletionResult() }
                if let suggestion = LaTeXCompletion.suggestion(in: text, at: caret.location),
                   let hint = LaTeXCompletion.inline(for: suggestion, labels: labels, citations: citations,
                       projectCommands: commands, projectEnvironments: environments),
                   let preview = LaTeXCompletion.inlinePreview(for: hint, in: text, at: caret.location) {
                    return CompletionResult(inline: hint, preview: preview)
                }
                guard let edit = LaTeXCompletion.delimiterHint(in: text, at: caret.location) else { return CompletionResult() }
                return CompletionResult(delimiter: edit,
                    preview: LaTeXCompletion.delimiterPreview(for: edit, in: text, at: caret.location))
            }
            self.completionScan = scan
            let result = await scan.value
            guard !Task.isCancelled, generation == self.completionGeneration,
                  self.contentRevision == revision, self.selectedRange() == caret, !self.hasMarkedText(),
                  self.window?.firstResponder === self else { return }
            let preview = result.preview.flatMap { self.inlineTailFits($0) ? $0 : nil }
            self.delimiterHint = preview == nil ? nil : result.delimiter
            self.inlineHint = preview == nil ? nil : result.inline
            self.inlinePreview = preview; self.needsDisplay = true
        }
    }

    private func dismissCompletions() {
        completionRequest = nil
        completionWork?.cancel(); completionScan?.cancel(); completionGeneration += 1
        if inlineHint != nil || inlinePreview != nil || delimiterHint != nil { inlineHint = nil; delimiterHint = nil; inlinePreview = nil; needsDisplay = true }
    }

    private var inlineHintAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 13),
         .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.65)]
    }

    private func inlineSourceTail(_ range: NSRange) -> NSAttributedString? {
        guard let storage = textStorage, let layout = layoutManager else { return nil }
        let text = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            var effective = NSRange()
            let attributes = layout.temporaryAttributes(atCharacterIndex: cursor, effectiveRange: &effective)
            let run = NSIntersectionRange(effective, range)
            guard run.length > 0 else { break }
            text.addAttributes(attributes, range: NSRange(location: run.location - range.location, length: run.length))
            cursor = NSMaxRange(run)
        }
        return text
    }

    private func inlineTailFits(_ preview: LaTeXCompletion.InlinePreview) -> Bool {
        guard let covered = preview.coveredTail, let trailing = preview.trailingText,
              let layout = layoutManager, let container = textContainer,
              let storage = textStorage else { return preview.coveredTail == nil }
        let glyphs = layout.glyphRange(forCharacterRange: covered, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let caret = caretRectInView()
        let lineHeight = layout.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 14, weight: .regular))
        let width = (preview.text as NSString).size(withAttributes: inlineHintAttributes).width
            + storage.attributedSubstring(from: trailing).size().width
        // Keep wrapped source text in its real layout. A short suffix can move
        // within this line without changing storage, selections or undo history.
        return rect.height <= lineHeight + 6 && caret.minX + width <= container.size.width + textContainerOrigin.x - container.lineFragmentPadding
    }

    /// Tab writes the hint. Returns false when there was nothing to write, so Tab can
    /// still indent.
    /// Writes a candidate over the typed prefix; environments also get their `\end`.
    @discardableResult
    func insert(candidate: String, in range: NSRange, context: LaTeXCompletion.Context) -> Bool {
        guard range.location >= 0, NSMaxRange(range) <= string.utf16.count else { return false }
        return insert(candidate: candidate, suggestion: .init(context: context, range: range,
                      prefix: (string as NSString).substring(with: range)))
    }

    @discardableResult
    private func insert(candidate: String, suggestion: LaTeXCompletion.Suggestion) -> Bool {
        guard !hasMarkedText() else { return false }
        let insertion = LaTeXCompletion.insertion(for: candidate, suggestion: suggestion, in: string)
        dismissCompletions(); endSnippet()
        let expected = NSMutableString(string: string)
        expected.replaceCharacters(in: insertion.range, with: insertion.text)
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        insertingCompletion = true
        insertText(insertion.text, replacementRange: insertion.range)
        insertingCompletion = false
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        guard string == expected as String else { return false }
        let origin = insertion.range.location
        if !insertion.placeholders.isEmpty {
            snippet = SnippetSession(ranges: insertion.placeholders.map {
                NSRange(location: origin + $0.location, length: $0.length)
            }, index: 0, finalOffset: origin + insertion.finalOffset)
            setSelectedRange(snippet!.ranges[0])
        } else { setSelectedRange(NSRange(location: origin + insertion.finalOffset, length: 0)) }
        needsDisplay = true
        return true
    }

    @discardableResult
    func acceptInlineHint() -> Bool {
        guard let hint = inlineHint else {
            guard !hasMarkedText(), selectedRange().length == 0,
                  let edit = delimiterHint ?? LaTeXCompletion.delimiterHint(in: string, at: selectedRange().location) else { return false }
            dismissCompletions(); endSnippet()
            insertingCompletion = true
            insertText(edit.text, replacementRange: edit.range)
            insertingCompletion = false
            setSelectedRange(NSRange(location: edit.range.location + edit.finalOffset, length: 0))
            return true
        }
        inlineHint = nil
        completionWork?.cancel(); completionScan?.cancel()
        return insert(candidate: hint.full, in: hint.range, context: hint.context)
    }

    override func keyDown(with event: NSEvent) {
        clearSourceLineHighlight()
        if !hasMarkedText(), event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                if advanceSnippet(backwards: true) { return }
            } else if acceptInlineHint() || advanceSnippet() { return }
        }
        super.keyDown(with: event)
    }

    // Keep AppKit's explicit Complete action on the same inline path.
    override func complete(_ sender: Any?) {
        if !acceptInlineHint() { refreshInlineHint() }
    }

    override func resignFirstResponder() -> Bool {
        dismissCompletions()
        return super.resignFirstResponder()
    }

    private func caretRectInView() -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let caret = selectedRange().location
        let ns = string as NSString
        let inset = textContainerOrigin
        guard ns.length > 0 else {
            let fragment = layout.extraLineFragmentRect
            return NSRect(x: inset.x, y: inset.y + fragment.minY, width: 2, height: max(14, fragment.height))
        }
        let anchor = min(max(0, caret - 1), ns.length - 1)
        let glyph = layout.glyphIndexForCharacter(at: anchor)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        box.origin.x += inset.x
        box.origin.y += inset.y
        let atLineStart = caret == 0 || ns.character(at: anchor) == 0x0A
        return NSRect(x: atLineStart ? fragment.minX + inset.x : box.maxX,
                      y: box.minY, width: 2, height: max(14, fragment.height))
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        let ns = string as NSString
        let selection = selectedRange()
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        insertText((string.contains("\r\n") ? "\r\n" : "\n") + indent, replacementRange: selection)
    }

    override func insertTab(_ sender: Any?) {
        if acceptInlineHint() { return }
        if advanceSnippet() { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if advanceSnippet(backwards: true) { return }
        super.insertBacktab(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if snippet != nil || inlineHint != nil || delimiterHint != nil {
            endSnippet(); dismissCompletions()
            return
        }
        super.cancelOperation(sender)
    }

    /// The hint is painted over the text view: nothing is written into the text
    /// storage, so undo, offsets and SyncTeX stay untouched.
    override func draw(_ dirtyRect: NSRect) {
        if !drawsBackground { backgroundColor.setFill(); dirtyRect.fill() }
        if let rect = sourceLineHighlightRect, rect.intersects(dirtyRect) {
            NSColor.black.withAlphaComponent(0.08).setFill()
            rect.intersection(dirtyRect).fill()
        }
        super.draw(dirtyRect)
        if let offset = subfileInsertionOffset, let layout = layoutManager, let container = textContainer,
           offset <= string.utf16.count {
            let glyph = offset < string.utf16.count ? layout.glyphIndexForCharacter(at: offset) : layout.numberOfGlyphs
            var line = glyph < layout.numberOfGlyphs ? layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil) : layout.extraLineFragmentRect
            if line.isEmpty { line.origin.y = layout.usedRect(for: container).maxY }
            let y = line.minY + textContainerOrigin.y
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSRect(x: textContainerOrigin.x + container.lineFragmentPadding, y: y,
                   width: max(0, container.size.width - container.lineFragmentPadding * 2), height: 2).fill()
        }
        guard let preview = inlinePreview,
              let hintRange = inlineHint?.range ?? delimiterHint?.range,
              NSMaxRange(hintRange) == selectedRange().location, sourceLineHighlightRange == nil else { return }
        let caret = caretRectInView()
        if let brace = preview.coveredTail ?? preview.coveredBrace, let layout = layoutManager, let container = textContainer {
            let glyphs = layout.glyphRange(forCharacterRange: brace, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            // Preserve the insertion point at the start of the preview.
            rect.origin.x = max(rect.minX, caret.minX + 1)
            backgroundColor.setFill()
            rect.fill()
        }
        let origin = NSPoint(x: caret.minX, y: caret.minY)
        (preview.text as NSString).draw(at: origin, withAttributes: inlineHintAttributes)
        if let trailing = preview.trailingText, let text = inlineSourceTail(trailing) {
            let width = (preview.text as NSString).size(withAttributes: inlineHintAttributes).width
            text.draw(at: NSPoint(x: origin.x + width, y: origin.y))
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if !insertingCompletion, !hasMarkedText(), let text = insertString as? String,
           let edit = LaTeXCompletion.typingInsertion(text, range: range, in: string, expandPairs: false), edit.text.isEmpty {
            if !edit.text.isEmpty { super.insertText(edit.text, replacementRange: edit.range) }
            let selection = edit.placeholders.first.map { NSRange(location: edit.range.location + $0.location, length: $0.length) }
                ?? NSRange(location: edit.range.location + edit.finalOffset, length: 0)
            setSelectedRange(selection)
            compositionEnded?()
            return
        }
        // Preserve an existing CRLF convention for native Return insertion.
        if let text = insertString as? String, text == "\n", string.contains("\r\n") {
            super.insertText("\r\n", replacementRange: replacementRange)
        } else { super.insertText(insertString, replacementRange: replacementRange) }
        compositionEnded?()
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange(), ns = string as NSString
        if !hasMarkedText(), selection.length == 0, selection.location > 0, selection.location < ns.length {
            let around = ns.substring(with: NSRange(location: selection.location - 1, length: 2))
            if ["{}", "()", "[]"].contains(around),
               LaTeXCompletion.typingInsertion(String(around.suffix(1)), range: selection, in: string)?.text == "" {
                super.insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))
                compositionEnded?()
                return
            }
        }
        super.deleteBackward(sender)
    }
}

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    /// Line holding the insertion point, drawn darker than the rest.
    var lineNumber: ((Int) -> Int)?
    var currentLine: Int?
    var diagnosticLines: [Int: BuildDiagnostic.Severity] = [:] {
        didSet {
            if diagnosticLines != oldValue {
                needsDisplay = true
                setAccessibilityValue(diagnosticLines.keys.sorted().map { "Line \($0): \(diagnosticLines[$0]!.title)" }.joined(separator: ", "))
            }
        }
    }
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Equal breathing room on both sides of the numbers.
    private static let margin: CGFloat = 10

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.thickness(forLineCount: 1)
    }

    /// Width the gutter needs for a document of this many lines: exactly as many
    /// digits as the largest number, never fewer than two, plus the margin twice.
    static func thickness(forLineCount count: Int) -> CGFloat {
        let digits = max(2, String(max(1, count)).count)
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        return ceil(digit * CGFloat(digits)) + margin * 2
    }

    /// Keeps the gutter in step with the document; only touches the layout when the
    /// number of digits actually changes.
    func updateThickness(lineCount: Int) {
        let wanted = Self.thickness(forLineCount: lineCount)
        guard abs(wanted - ruleThickness) > 0.5 else { return }
        ruleThickness = wanted
        enclosingScrollView?.tile()
        needsDisplay = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor(calibratedWhite: 0.98, alpha: 1).setFill(); bounds.fill()
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let text = view.string as NSString
        let font = Self.font
        let idle: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let active: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let visible = view.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var position = text.lineRange(for: NSRange(location: min(chars.location, text.length), length: 0)).location
        var number = lineNumber?(position) ?? EditorSurface.lineNumber(atCharacter: position, in: view.string)
        while position <= text.length {
            var origin: NSPoint
            if position == text.length {
                guard position == 0 || text.substring(from: max(0, position - 1)) == "\n" else { break }
                origin = layout.extraLineFragmentRect.origin
            } else {
                let glyph = layout.glyphIndexForCharacter(at: position)
                origin = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).origin
            }
            let point = convert(NSPoint(x: 0, y: origin.y + view.textContainerOrigin.y + 2), from: view)
            if point.y > bounds.maxY + 30 { break }
            if point.y >= -20 {
                let attributes = number == currentLine ? active : idle
                let label = "\(number)" as NSString
                label.draw(at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - Self.margin, y: point.y), withAttributes: attributes)
                if let severity = diagnosticLines[number] {
                    (severity == .error ? NSColor.systemRed : NSColor.systemOrange).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 3, y: point.y + 4, width: 4, height: 4)).fill()
                }
            }
            if position == text.length { break }
            let next = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
            if next <= position { break }
            position = next; number += 1
        }
    }
}

/// UTF-16 line starts shared by caret navigation and gutter drawing.
struct SourceLineIndex {
    private(set) var starts = [0]
    private var length = 0
    var count: Int { starts.count }

    private func upperBound(_ offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
    func lineNumber(at offset: Int) -> Int { max(1, upperBound(min(max(0, offset), length))) }

    mutating func reset(_ text: NSString) {
        length = text.length
        starts = scannedStarts(text, from: 0, to: length)
        if text.lineRange(for: NSRange(location: length, length: 0)).location == length { starts.append(length) }
        if starts.isEmpty { starts = [0] }
    }
    mutating func update(_ text: NSString, editedRange: NSRange, delta: Int) {
        let removedLength = editedRange.length - delta
        guard text.length == length + delta, removedLength >= 0,
              editedRange.location <= length, editedRange.location + removedLength <= length else { reset(text); return }
        // Include a line on each side, so edits splitting/joining CRLF stay correct.
        let first = max(0, upperBound(editedRange.location) - 2)
        let resume = min(starts.count, upperBound(editedRange.location + removedLength) + 1)
        let end = (resume < starts.count ? starts[resume] : length) + delta
        var updated = Array(starts[..<first]) + scannedStarts(text, from: starts[first], to: end)
        if resume < starts.count { updated += starts[resume...].map { $0 + delta } }
        else if text.lineRange(for: NSRange(location: text.length, length: 0)).location == text.length { updated.append(text.length) }
        starts = updated.isEmpty ? [0] : updated
        length = text.length
    }
    private func scannedStarts(_ text: NSString, from start: Int, to end: Int) -> [Int] {
        var result: [Int] = [], position = start
        while position < end {
            result.append(position)
            let next = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
            guard next > position else { break }
            position = next
        }
        return result
    }
}
