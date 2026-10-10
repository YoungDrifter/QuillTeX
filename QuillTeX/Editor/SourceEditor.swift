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
final class EditorSurface: NSScrollView, NSTextViewDelegate {
    let textView = SourceTextView()
    weak var source: SourceDocument?
    weak var store: ProjectStore?
    private var highlighting: DispatchWorkItem?
    private var changingAttributes = false
    /// The ruler draws the caret's line darker, so the eye keeps its place.
    func updateCurrentLine() {
        setCurrentLine(lineNumber(atCharacter: textView.selectedRange().location))
    }
    /// One-based number of the line holding a UTF-16 character offset.
    func lineNumber(atCharacter index: Int) -> Int {
        Self.lineNumber(atCharacter: index, in: textView.string)
    }

    static func lineNumber(atCharacter index: Int, in string: String) -> Int {
        let text = string as NSString
        var line = 1, position = 0
        let limit = min(max(0, index), text.length)
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

    init(document: SourceDocument, store: ProjectStore) {
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
        textView.completionAccepted = { [weak self] in _ = self?.textView.acceptPanelSelection() }
        textView.allowsUndo = true; textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
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
        textView.delegate = self
        textView.compositionEnded = { [weak self] in self?.compositionDidEnd() }
        textView.commandClickLine = { [weak self] line in self?.store?.syncSourceToPDF(line: line) }
        textView.completionLabels = { [weak self] in self?.store?.index.labels ?? [] }
        textView.completionCitations = { [weak self] in self?.store?.index.citations ?? [] }
        verticalRulerView = LineNumberRuler(textView: textView)
        hasVerticalRuler = true; rulersVisible = true
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: contentView)
        textView.setSelectedRange(NSRange(location: min(document.selection.location, (document.text as NSString).length), length: 0))
        highlight()
        refreshGutter()
        updateCurrentLine()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.contentView.scroll(to: document.scrollOrigin)
            if document.selection.location > 0 { self.textView.scrollRangeToVisible(document.selection) }
            self.reflectScrolledClipView(self.contentView)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func didScroll() {
        source?.scrollOrigin = contentView.bounds.origin
        verticalRulerView?.needsDisplay = true
    }
    func textDidChange(_ notification: Notification) {
        guard !changingAttributes, let source else { return }
        source.text = textView.string; source.selection = textView.selectedRange()
        source.hasMarkedText = textView.hasMarkedText()
        refreshGutter()
        updateCurrentLine()
        textView.refreshInlineHint()
        if !source.hasMarkedText { store?.edited(source); scheduleHighlight(); textView.scheduleCandidateBox() }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        source?.selection = textView.selectedRange()
        source?.hasMarkedText = textView.hasMarkedText()
        updateCurrentLine()
        textView.refreshInlineHint()
    }
    private func compositionDidEnd() {
        guard let source else { return }
        source.hasMarkedText = textView.hasMarkedText()
        if !source.hasMarkedText {
            source.text = textView.string; store?.edited(source); scheduleHighlight()
        }
    }
    func navigate(to range: NSRange) {
        textView.setSelectedRange(range); textView.scrollRangeToVisible(range)
        source?.selection = range
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.window?.makeFirstResponder(self.textView)
        }
    }
    func reloadFromDisk() {
        guard let source, !textView.hasMarkedText() else { return }
        let previous = contentView.bounds.origin
        textView.string = source.text
        let location = min(source.selection.location, (source.text as NSString).length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.undoManager?.removeAllActions()
        contentView.scroll(to: previous); reflectScrolledClipView(contentView)
        highlight(); refreshGutter()
    }
    /// Line numbers are as wide as the document needs, so a short file gets a narrow
    /// gutter instead of a fixed one with a lopsided margin.
    private func refreshGutter() {
        (verticalRulerView as? LineNumberRuler)?.updateThickness(for: textView.string)
        verticalRulerView?.needsDisplay = true
    }
    private func scheduleHighlight() {
        highlighting?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        highlighting = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func highlight() {
        guard !textView.hasMarkedText(), let layout = textView.layoutManager else { return }
        // Temporary layout attributes do not alter text storage or the undo stack.
        let text = textView.string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        // Typed spans from the LaTeX scanner, painted with the editor palette.
        for span in LaTeXHighlighter.spans(in: text) {
            layout.addTemporaryAttribute(.foregroundColor, value: LaTeXPalette.color(for: span), forCharacterRange: span.range)
        }
    }
}

final class SourceTextView: NSTextView {
    var documentUndoManager = UndoManager()
    var completionAccepted: (() -> Void)? {
        didSet { completionPanel.onAccept = completionAccepted }
    }
    override var undoManager: UndoManager? { documentUndoManager }
    var compositionEnded: (() -> Void)?
    /// Called with the 1-based line under a ⌘-click, for source → PDF sync.
    var commandClickLine: ((Int) -> Void)?
    /// Candidates that come from the project rather than from a fixed list.
    var completionLabels: () -> [String] = { [] }
    var completionCitations: () -> [String] = { [] }
    /// Faint hint drawn after the caret; Tab writes it, anything else replaces it.
    private var inlineHint: LaTeXCompletion.Inline?
    private var popupWork: DispatchWorkItem?
    /// The candidate box and what it is offering.
    private let completionPanel = CompletionPanel()
    private var panelSuggestion: LaTeXCompletion.Suggestion?
    override func unmarkText() { super.unmarkText(); compositionEnded?() }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.modifierFlags.contains(.command),
              let layout = layoutManager, let container = textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layout.characterIndex(for: inContainer, in: container,
                                          fractionOfDistanceBetweenInsertionPoints: nil)
        commandClickLine?(EditorSurface.lineNumber(atCharacter: index, in: string))
    }
    // MARK: - Completion

    /// What the popup is completing: the command, the environment, a label, a key.
    private func currentSuggestion() -> LaTeXCompletion.Suggestion? {
        LaTeXCompletion.suggestion(in: string, at: selectedRange().location)
    }

    override var rangeForUserCompletion: NSRange {
        currentSuggestion()?.range ?? super.rangeForUserCompletion
    }

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        guard let suggestion = LaTeXCompletion.suggestion(in: string, at: NSMaxRange(charRange)) else { return nil }
        let list = LaTeXCompletion.candidates(for: suggestion,
                                              labels: completionLabels(),
                                              citations: completionCitations())
        index?.pointee = 0
        return list
    }

    /// Environments get their `\end` written at the same time, with the caret parked
    /// on the blank line between the two.
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal: Bool) {
        guard isFinal,
              let suggestion = LaTeXCompletion.suggestion(in: string, at: NSMaxRange(charRange)),
              let expansion = LaTeXCompletion.expansion(for: word, context: suggestion.context) else {
            super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: isFinal)
            return
        }
        guard shouldChangeText(in: charRange, replacementString: expansion.text) else { return }
        replaceCharacters(in: charRange, with: expansion.text)
        didChangeText()
        let caret = NSMaxRange(charRange) + (expansion.text as NSString).length - expansion.caretBack
        setSelectedRange(NSRange(location: max(charRange.location, caret), length: 0))
    }

    // MARK: - Inline hint and the candidate box

    /// Recomputes the ghost text for wherever the caret is now.
    func refreshInlineHint() {
        popupWork?.cancel()
        guard !hasMarkedText(), window?.firstResponder === self else {
            if inlineHint != nil { inlineHint = nil; needsDisplay = true }
            return
        }
        let next = LaTeXCompletion.inline(in: string, at: selectedRange().location,
                                          labels: completionLabels(), citations: completionCitations())
        if next != inlineHint { inlineHint = next; needsDisplay = true }
        if next == nil, completionPanel.isVisible, !hasMarkedText() { completionPanel.hide() }
    }

    /// TeXifier-style: the candidate box opens on its own while a command, an
    /// environment, a label or a key is being typed — a short pause after the last
    /// keystroke, so it never fights with typing.
    func scheduleCandidateBox() {
        popupWork?.cancel()
        guard !hasMarkedText() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasMarkedText(), self.window?.firstResponder === self else { return }
            guard let suggestion = LaTeXCompletion.suggestion(in: self.string, at: self.selectedRange().location) else {
                self.panelSuggestion = nil
                self.completionPanel.hide()
                return
            }
            let items = LaTeXCompletion.items(for: suggestion,
                                               labels: self.completionLabels(),
                                               citations: self.completionCitations())
            self.panelSuggestion = suggestion
            self.completionPanel.show(items: items, selection: 0, under: self.caretRectInScreen())
        }
        popupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Tab writes the hint. Returns false when there was nothing to write, so Tab can
    /// still indent.
    /// Writes a candidate over the typed prefix; environments also get their `\end`.
    @discardableResult
    func insert(candidate: String, in range: NSRange, context: LaTeXCompletion.Context) -> Bool {
        var text = candidate
        var caretBack = 0
        if let expansion = LaTeXCompletion.expansion(for: candidate, context: context) {
            text = expansion.text
            caretBack = expansion.caretBack
        }
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        replaceCharacters(in: range, with: text)
        didChangeText()
        let caret = NSMaxRange(range) + (text as NSString).length - caretBack
        setSelectedRange(NSRange(location: max(range.location, caret), length: 0))
        needsDisplay = true
        return true
    }

    @discardableResult
    func acceptInlineHint() -> Bool {
        guard let hint = inlineHint else { return false }
        inlineHint = nil
        popupWork?.cancel()
        completionPanel.hide()
        return insert(candidate: hint.full, in: hint.range, context: hint.context)
    }

    // MARK: - Candidate box keys

    /// The panel never becomes key: the text view keeps the keyboard and forwards the
    /// keys the list needs, so typing is never interrupted.
    override func keyDown(with event: NSEvent) {
        if completionPanel.isVisible {
            switch event.keyCode {
            case 53: completionPanel.hide(); return                        // escape
            case 48: if acceptPanelSelection() { return }                  // tab
            case 36, 76: if acceptPanelSelection() { return }              // return, enter
            case 125: completionPanel.moveSelection(by: 1); return         // down
            case 126: completionPanel.moveSelection(by: -1); return        // up
            default: break
            }
        }
        super.keyDown(with: event)
    }

    @discardableResult
    func acceptPanelSelection() -> Bool {
        guard let suggestion = panelSuggestion, let item = completionPanel.selectedItem else { return false }
        completionPanel.hide()
        panelSuggestion = nil
        return insert(candidate: item.title, in: suggestion.range, context: suggestion.context)
    }

    override func resignFirstResponder() -> Bool {
        completionPanel.hide()
        panelSuggestion = nil
        return super.resignFirstResponder()
    }

    /// Where the caret is on screen, for placing the candidate box under it.
    func caretRectInScreen() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(caretRectInView(), to: nil))
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

    override func insertTab(_ sender: Any?) {
        if acceptInlineHint() { return }
        super.insertTab(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if inlineHint != nil {
            inlineHint = nil; popupWork?.cancel(); needsDisplay = true
            return
        }
        super.cancelOperation(sender)
    }

    /// The hint is painted over the text view: nothing is written into the text
    /// storage, so undo, offsets and SyncTeX stay untouched.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let hint = inlineHint else { return }
        let caret = caretRectInView()
        let origin = NSPoint(x: caret.minX, y: caret.minY)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.65)
        ]
        (hint.remainder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        // Preserve an existing CRLF convention for native Return insertion.
        if let text = insertString as? String, text == "\n", string.contains("\r\n") {
            super.insertText("\r\n", replacementRange: replacementRange)
        } else { super.insertText(insertString, replacementRange: replacementRange) }
        compositionEnded?()
    }
}

final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?
    /// Line holding the insertion point, drawn darker than the rest.
    var currentLine: Int?
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
    func updateThickness(for text: String) {
        var lines = 1
        for scalar in text.unicodeScalars where scalar == "\n" { lines += 1 }
        let wanted = Self.thickness(forLineCount: lines)
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
        let prefix = text.substring(to: position)
        var number = prefix.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
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
            }
            if position == text.length { break }
            let next = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
            if next <= position { break }
            position = next; number += 1
        }
    }
}
