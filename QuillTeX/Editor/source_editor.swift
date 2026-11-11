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
    private var restoringScrollAfterWindowReturn = false
    private var lastLayoutWidth: CGFloat = 0
    private var widthRestoreGeneration = 0
    /// Last reading anchor captured while scrolling; AppKit may reset the clip
    /// bounds before `layout()` runs, so the anchor cannot be read there.
    private var lastTopVisibleCharacter: Int?
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
        // Content starts at the top edge; pulling past the top reveals the native
        // elastic gap instead of reserving a permanent blank band.
        verticalScrollElasticity = .allowed
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
        textView.textContainerInset = NSSize(width: 16, height: ChromeMetrics.paneHeaderHeight)
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
        textView.completionRoot = { [weak self] in self?.store?.root }
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
                // A non-zero origin is a position to preserve (for example after
                // switching pane modes). Only bring the caret into view when the
                // document is opening at the very top.
                if restoredScrollOrigin == .zero, document.selection.location > 0 {
                    self.textView.scrollRangeToVisible(document.selection)
                }
            }
            self.reflectScrolledClipView(self.contentView)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Keep the line at the top in place when the editor changes width. Without
    /// this, re-wrapping after Editor Only → Editor + PDF leaves the same pixel
    /// offset, so the visible text appears to jump upwards.
    override func layout() {
        let previousWidth = lastLayoutWidth
        let anchor = previousWidth > 0 && abs(bounds.width - previousWidth) > 0.5
            ? (lastTopVisibleCharacter ?? topVisibleCharacterOffset()) : nil
        super.layout()
        lastLayoutWidth = bounds.width
        guard let anchor else { return }
        // Text re-wrapping settles after the scroll view lays out its new width;
        // restore on the next pass so the line position uses the new layout.
        widthRestoreGeneration += 1
        let generation = widthRestoreGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.widthRestoreGeneration == generation, self.window != nil else { return }
            self.layoutSubtreeIfNeeded()
            self.restoreTopVisibleCharacter(anchor)
            self.lastTopVisibleCharacter = anchor
        }
    }

    /// First character visible at the top of the editor. Used to keep the reading
    /// position stable across width changes.
    func topVisibleCharacterOffset() -> Int? {
        let visible = contentView.bounds
        guard visible.origin.y > 0, visible.width > 0, visible.height > 0,
              let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let rect = NSRect(x: visible.minX - textView.textContainerOrigin.x,
                          y: visible.minY - textView.textContainerOrigin.y,
                          width: visible.width, height: visible.height)
        let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
        guard glyphs.length > 0 else { return nil }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return min(chars.location, (textView.string as NSString).length)
    }

    private func restoreTopVisibleCharacter(_ offset: Int) {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        let position = min(max(0, offset), length)
        layout.ensureLayout(for: container)
        let line: NSRect
        if position < layout.numberOfGlyphs {
            let glyph = layout.glyphIndexForCharacter(at: position)
            line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            line = layout.extraLineFragmentRect
        }
        let target = max(0, line.minY + textView.textContainerOrigin.y)
        guard abs(contentView.bounds.origin.y - target) > 0.5 else { return }
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: target))
        reflectScrolledClipView(contentView)
    }

    /// Collapsing a split pane takes the editor out of its window, which can
    /// reset the clip view to the top. Put the saved position back when the
    /// editor returns, so switching to PDF Only and back never jumps the text.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !initialPositionRestorePending, let source else { return }
        let origin = source.scrollOrigin
        guard origin != .zero else { return }
        restoringScrollAfterWindowReturn = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoringScrollAfterWindowReturn = false
            guard self.window != nil else { return }
            self.layoutSubtreeIfNeeded()
            self.contentView.scroll(to: origin)
            self.reflectScrolledClipView(self.contentView)
        }
    }

    @objc private func didScroll() {
        // Collapsing the split item removes the editor from its window and can
        // reset the clip bounds to zero. Do not overwrite the position the user
        // will return to when the pane is shown again.
        if restoringScrollAfterWindowReturn { return }
        guard window != nil else { return }
        textView.closeCandidates()
        source?.scrollOrigin = contentView.bounds.origin
        if let top = topVisibleCharacterOffset() { lastTopVisibleCharacter = top }
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
    let completionSession = CompletionSession()
    var contentRevision = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        completionViewDidMoveToWindow()
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        completionWillChangeText(in: affectedCharRange, replacementString: replacementString)
        return true
    }
    override func didChangeText() {
        contentRevision += 1
        super.didChangeText()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        closeCandidates(); dismissCompletions()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func unmarkText() { super.unmarkText(); compositionEnded?() }
    override func mouseDown(with event: NSEvent) {
        closeCandidates(); dismissCompletions()
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
        drawCompletionHint()
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
        if wantsCandidates { closeCandidates(); return }
        if snippet != nil || inlineHint != nil || delimiterHint != nil {
            endSnippet(); dismissCompletions()
            return
        }
        super.cancelOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        clearSourceLineHighlight()
        if !completionKeyDown(event) { super.keyDown(with: event) }
    }
    override func complete(_ sender: Any?) { showCandidates() }
    override func resignFirstResponder() -> Bool {
        closeCandidates(); dismissCompletions()
        return super.resignFirstResponder()
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        if completionHandlesInsertion(insertString, range: range) { return }
        // Preserve an existing CRLF convention for native Return insertion.
        if let text = insertString as? String, text == "\n", string.contains("\r\n") {
            super.insertText("\r\n", replacementRange: replacementRange)
        } else { super.insertText(insertString, replacementRange: replacementRange) }
        compositionEnded?()
    }

    override func deleteBackward(_ sender: Any?) {
        if completionDeletesPair() { return }
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
