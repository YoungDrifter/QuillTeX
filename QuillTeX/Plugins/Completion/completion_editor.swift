import AppKit

@MainActor
final class CompletionSession {
    struct CompletionResult: Sendable {
        var suggestion: LaTeXCompletion.Suggestion?
        var candidates: [LaTeXCompletion.Candidate] = []
        var delimiter: LaTeXCompletion.Insertion?
        var inline: LaTeXCompletion.Inline?
        var preview: LaTeXCompletion.InlinePreview?
    }
    struct SnippetSession {
        var ranges: [NSRange]
        var index: Int
        var finalOffset: Int
    }
    var completionRoot: () -> URL? = { nil }
    var completionPopup: CompletionPopup?
    var wantsCandidates = false
    var popupSuggestion: LaTeXCompletion.Suggestion?
    var completionLabels: () -> [String] = { [] }
    var completionCitations: () -> [String] = { [] }
    var completionCommands: () -> [String] = { [] }
    var completionEnvironments: () -> [String] = { [] }
    var inlineHint: LaTeXCompletion.Inline?
    var delimiterHint: LaTeXCompletion.Insertion?
    var inlinePreview: LaTeXCompletion.InlinePreview?
    var completionWork: Task<Void, Never>?
    var completionScan: Task<CompletionSession.CompletionResult, Never>?
    var completionGeneration = 0
    var completionRequest: (revision: Int, length: Int, caret: NSRange)?
    var snippet: SnippetSession?
    var insertingCompletion = false
    var previewSpacing: CompletionPreviewSpacing?
}

extension SourceTextView {
    var completionRoot: () -> URL? { get { completionSession.completionRoot } set { completionSession.completionRoot = newValue } }
    var completionPopup: CompletionPopup? { get { completionSession.completionPopup } set { completionSession.completionPopup = newValue } }
    var wantsCandidates: Bool { get { completionSession.wantsCandidates } set { completionSession.wantsCandidates = newValue } }
    var popupSuggestion: LaTeXCompletion.Suggestion? { get { completionSession.popupSuggestion } set { completionSession.popupSuggestion = newValue } }
    var completionLabels: () -> [String] { get { completionSession.completionLabels } set { completionSession.completionLabels = newValue } }
    var completionCitations: () -> [String] { get { completionSession.completionCitations } set { completionSession.completionCitations = newValue } }
    var completionCommands: () -> [String] { get { completionSession.completionCommands } set { completionSession.completionCommands = newValue } }
    var completionEnvironments: () -> [String] { get { completionSession.completionEnvironments } set { completionSession.completionEnvironments = newValue } }
    var inlineHint: LaTeXCompletion.Inline? { get { completionSession.inlineHint } set { completionSession.inlineHint = newValue } }
    var delimiterHint: LaTeXCompletion.Insertion? { get { completionSession.delimiterHint } set { completionSession.delimiterHint = newValue } }
    var inlinePreview: LaTeXCompletion.InlinePreview? {
        get { completionSession.inlinePreview }
        set { completionSession.inlinePreview = newValue; updateCompletionPreviewSpacing() }
    }
    var completionWork: Task<Void, Never>? { get { completionSession.completionWork } set { completionSession.completionWork = newValue } }
    var completionScan: Task<CompletionSession.CompletionResult, Never>? { get { completionSession.completionScan } set { completionSession.completionScan = newValue } }
    var completionGeneration: Int { get { completionSession.completionGeneration } set { completionSession.completionGeneration = newValue } }
    var completionRequest: (revision: Int, length: Int, caret: NSRange)? { get { completionSession.completionRequest } set { completionSession.completionRequest = newValue } }
    var snippet: CompletionSession.SnippetSession? { get { completionSession.snippet } set { completionSession.snippet = newValue } }
    var insertingCompletion: Bool { get { completionSession.insertingCompletion } set { completionSession.insertingCompletion = newValue } }
    var completionEnabled: Bool { PluginManager.shared.isEnabled(PluginManager.completionID) }
    @objc func completionSettingsChanged(_ notification: Notification) {
        guard notification.object as? String == PluginManager.completionID else { return }
        closeCandidates(); dismissCompletions(); endSnippet()
        if completionEnabled { refreshInlineHint() }
    }
    func closeCandidates() {
        wantsCandidates = false; popupSuggestion = nil; completionPopup?.close()
    }
    func showCandidates() {
        guard completionEnabled, !hasMarkedText(), selectedRange().length == 0 else { return }
        wantsCandidates = true
        refreshInlineHint()
    }
    func acceptCandidate() -> Bool {
        guard completionEnabled, !hasMarkedText(), let value = completionPopup?.selected,
              let suggestion = popupSuggestion,
              LaTeXCompletion.suggestion(in: string, at: selectedRange().location) == suggestion else { closeCandidates(); return false }
        closeCandidates()
        return insert(candidate: value, suggestion: suggestion)
    }
    /// Faint hint drawn after the caret; Tab writes it, anything else replaces it.
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
        guard completionEnabled, !hasMarkedText(), var session = snippet else { return false }
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

    func completionViewDidMoveToWindow() {
        NotificationCenter.default.removeObserver(self, name: PluginManager.settingsChanged, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(completionSettingsChanged(_:)), name: PluginManager.settingsChanged, object: nil)
        } else { closeCandidates(); dismissCompletions(); endSnippet() }
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
    func scheduleCompletions() {
        guard completionEnabled, !hasMarkedText(), selectedRange().length == 0, window?.firstResponder === self else {
            closeCandidates()
            dismissCompletions()
            return
        }
        let options = PluginManager.shared.completionOptions
        let root = completionRoot()
        let text = string, caret = selectedRange()
        if let previous = completionRequest, previous.caret == caret, previous.revision == contentRevision, previous.length == (text as NSString).length { return }
        let requested = wantsCandidates
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
                guard !Task.isCancelled else { return CompletionSession.CompletionResult() }
                var result = CompletionSession.CompletionResult()
                if let suggestion = LaTeXCompletion.suggestion(in: text, at: caret.location), options.allows(suggestion.context) {
                    let paths = (suggestion.context == .texPath || suggestion.context == .imagePath)
                        ? CompletionPaths.candidates(root: root, images: suggestion.context == .imagePath) : []
                    let candidates = LaTeXCompletion.candidates(for: suggestion, labels: labels, citations: citations,
                        projectCommands: commands, projectEnvironments: environments, paths: paths)
                    if requested { result.suggestion = suggestion; result.candidates = candidates.map { LaTeXCompletion.candidate($0, suggestion: suggestion, source: text) } }
                    if options.automatic, let hint = LaTeXCompletion.inline(for: suggestion, labels: labels, citations: citations,
                        projectCommands: commands, projectEnvironments: environments, paths: paths),
                        let preview = LaTeXCompletion.inlinePreview(for: hint, in: text, at: caret.location) {
                        result.inline = hint; result.preview = preview
                        return result
                    }
                }
                if options.automatic, let edit = LaTeXCompletion.delimiterHint(in: text, at: caret.location),
                   (edit.text.contains("\\end{") ? options.environmentEnd : options.pairs) {
                    result.delimiter = edit
                    result.preview = LaTeXCompletion.delimiterPreview(for: edit, in: text, at: caret.location)
                }
                return result
            }
            self.completionScan = scan
            let result = await scan.value
            guard !Task.isCancelled, generation == self.completionGeneration,
                  self.contentRevision == revision, self.selectedRange() == caret, self.completionRoot() == root, !self.hasMarkedText(),
                  self.window?.firstResponder === self else { return }
            if requested, self.wantsCandidates, let owner = self.window {
                if self.completionPopup == nil { self.completionPopup = CompletionPopup() }
                self.popupSuggestion = result.suggestion
                self.completionPopup?.accept = { [weak self] _ in _ = self?.acceptCandidate() }
                let anchor = owner.convertToScreen(self.convert(self.caretRectInView(), to: nil))
                self.completionPopup?.show(result.candidates, anchor: anchor, owner: owner)
            }
            let preview = result.preview.flatMap { self.inlineTailFits($0) ? $0 : nil }
            self.delimiterHint = preview == nil ? nil : result.delimiter
            self.inlineHint = preview == nil ? nil : result.inline
            self.inlinePreview = preview; self.needsDisplay = true
        }
    }

    func dismissCompletions() {
        completionRequest = nil
        completionWork?.cancel(); completionScan?.cancel(); completionGeneration += 1
        if inlineHint != nil || inlinePreview != nil || delimiterHint != nil { inlineHint = nil; delimiterHint = nil; inlinePreview = nil; needsDisplay = true }
    }

    var inlineHintAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 13),
         .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.65)]
    }

    func inlineSourceTail(_ range: NSRange) -> NSAttributedString? {
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

    func inlineTailFits(_ preview: LaTeXCompletion.InlinePreview) -> Bool {
        if preview.text.contains("\n") {
            // Multiline environment hints must never cover authored text on this line.
            guard preview.trailingText == nil, let container = textContainer else { return false }
            return preview.text.components(separatedBy: "\n").dropFirst().allSatisfy {
                ($0 as NSString).size(withAttributes: inlineHintAttributes).width <= container.size.width - container.lineFragmentPadding * 2
            }
        }
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
    /// Accept only this stage; closing environments are separate proposals.
    @discardableResult
    func insert(candidate: String, in range: NSRange, context: LaTeXCompletion.Context) -> Bool {
        guard range.location >= 0, NSMaxRange(range) <= string.utf16.count else { return false }
        return insert(candidate: candidate, suggestion: .init(context: context, range: range,
                      prefix: (string as NSString).substring(with: range)))
    }

    @discardableResult
    func insert(candidate: String, suggestion: LaTeXCompletion.Suggestion) -> Bool {
        guard completionEnabled, !hasMarkedText(), PluginManager.shared.completionOptions.allows(suggestion.context) else { return false }
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
            snippet = CompletionSession.SnippetSession(ranges: insertion.placeholders.map {
                NSRange(location: origin + $0.location, length: $0.length)
            }, index: 0, finalOffset: origin + insertion.finalOffset)
            setSelectedRange(snippet!.ranges[0])
        } else { setSelectedRange(NSRange(location: origin + insertion.finalOffset, length: 0)) }
        needsDisplay = true
        refreshInlineHint()
        return true
    }

    @discardableResult
    func acceptInlineHint() -> Bool {
        guard completionEnabled, PluginManager.shared.completionOptions.automatic else { return false }
        guard let hint = inlineHint else {
            guard !hasMarkedText(), selectedRange().length == 0,
                  let edit = delimiterHint ?? LaTeXCompletion.delimiterHint(in: string, at: selectedRange().location),
                  (edit.text.contains("\\end{") ? PluginManager.shared.completionOptions.environmentEnd : PluginManager.shared.completionOptions.pairs) else { return false }
            dismissCompletions(); endSnippet()
            breakUndoCoalescing()
            undoManager?.beginUndoGrouping()
            insertingCompletion = true
            insertText(edit.text, replacementRange: edit.range)
            insertingCompletion = false
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
            setSelectedRange(NSRange(location: edit.range.location + edit.finalOffset, length: 0))
            return true
        }
        inlineHint = nil
        completionWork?.cancel(); completionScan?.cancel()
        return insert(candidate: hint.full, in: hint.range, context: hint.context)
    }

    func completionKeyDown(_ event: NSEvent) -> Bool {
        
        if completionEnabled, !hasMarkedText() {
            if PluginManager.shared.completionShortcut.matches(event) { showCandidates(); return true }
            if completionPopup?.isVisible == true {
                switch event.keyCode {
                case 125: completionPopup?.move(1); return true
                case 126: completionPopup?.move(-1); return true
                case 36, 48: if acceptCandidate() { return true }
                case 53: closeCandidates(); return true
                default: break
                }
            }
        }
        if completionEnabled, !hasMarkedText(), event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                if advanceSnippet(backwards: true) { return true }
            } else if acceptInlineHint() || advanceSnippet() { return true }
        }
        if [115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) { closeCandidates() }
        return false
    }

    // Keep AppKit's explicit Complete action on the same inline path.




    func caretRectInView() -> NSRect {
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

    /// The hint is painted over the text view: nothing is written into the text
    /// storage, so undo, offsets and SyncTeX stay untouched.
    func drawCompletionHint() {
        guard let preview = inlinePreview,
              let hintRange = inlineHint?.range ?? delimiterHint?.range,
              NSMaxRange(hintRange) == selectedRange().location, sourceLineHighlightRange == nil else { return }
        let caret = caretRectInView()
        if preview.text.contains("\n") {
            for line in multilineHintLines(preview, caret: caret) {
                (line.text as NSString).draw(at: line.origin, withAttributes: inlineHintAttributes)
            }
            return
        }
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

    /// Blank preview lines occupy their normal line pitch; existing source is never painted over.
    func multilineHintLines(_ preview: LaTeXCompletion.InlinePreview, caret: NSRect) -> [(text: String, origin: NSPoint)] {
        guard let layout = layoutManager, let container = textContainer else { return [] }
        let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let pitch = layout.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 14, weight: .regular)) + (paragraph?.lineSpacing ?? 0)
        let left = textContainerOrigin.x + container.lineFragmentPadding
        return preview.text.components(separatedBy: "\n").enumerated().compactMap { index, text in
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (text, NSPoint(x: index == 0 ? caret.minX : left, y: caret.minY + CGFloat(index) * pitch))
        }
    }

    func updateCompletionPreviewSpacing() {
        guard let layout = layoutManager else { return }
        if let previous = completionSession.previewSpacing {
            layout.delegate = previous.previousDelegate
            completionSession.previewSpacing = nil
            // During text-storage notifications, AppKit still owns glyph invalidation.
            if layout.textStorage?.editedMask.isEmpty != false {
                layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: string.utf16.count), actualCharacterRange: nil)
            }
        }
        guard let preview = completionSession.inlinePreview, preview.text.contains("\n"),
              let container = textContainer, selectedRange().length == 0 else { return }
        let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle
        let pitch = layout.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 14, weight: .regular)) + (paragraph?.lineSpacing ?? 0)
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: min(selectedRange().location, ns.length), length: 0))
        let spacing = CompletionPreviewSpacing(line: line, extra: CGFloat(preview.text.components(separatedBy: "\n").count - 1) * pitch,
                                              previous: layout.delegate)
        completionSession.previewSpacing = spacing
        layout.delegate = spacing
        layout.invalidateLayout(forCharacterRange: line, actualCharacterRange: nil)
        layout.ensureLayout(for: container)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func completionWillChangeText(in affectedCharRange: NSRange, replacementString: String?) {
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
    }
    func completionHandlesInsertion(_ input: Any, range: NSRange) -> Bool {
        if completionEnabled, PluginManager.shared.completionOptions.pairs, !insertingCompletion, !hasMarkedText(), let text = input as? String,
           let edit = LaTeXCompletion.typingInsertion(text, range: range, in: string, expandPairs: false), edit.text.isEmpty {
            let selection = edit.placeholders.first.map { NSRange(location: edit.range.location + $0.location, length: $0.length) }
                ?? NSRange(location: edit.range.location + edit.finalOffset, length: 0)
            setSelectedRange(selection)
            compositionEnded?()
            return true
        }
        return false
    }
    func completionDeletesPair() -> Bool {
        let selection = selectedRange(), ns = string as NSString
        if completionEnabled, PluginManager.shared.completionOptions.pairs, !hasMarkedText(), selection.length == 0, selection.location > 0, selection.location < ns.length {
            let around = ns.substring(with: NSRange(location: selection.location - 1, length: 2))
            if ["{}", "()", "[]"].contains(around),
               LaTeXCompletion.typingInsertion(String(around.suffix(1)), range: selection, in: string)?.text == "" {
                insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))
                compositionEnded?()
                return true
            }
        }
        return false
    }
}

/// Temporary typesetting space belongs to the preview, leaving text, undo and offsets untouched.
final class CompletionPreviewSpacing: NSObject, NSLayoutManagerDelegate {
    let line: NSRange
    let extra: CGFloat
    weak var previousDelegate: NSLayoutManagerDelegate?
    init(line: NSRange, extra: CGFloat, previous: NSLayoutManagerDelegate?) {
        self.line = line; self.extra = extra; self.previousDelegate = previous
    }
    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard glyphIndex < layoutManager.numberOfGlyphs else { return 0 }
        let index = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard let storage = layoutManager.textStorage, index < storage.length else { return 0 }
        let paragraph = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        return (paragraph?.paragraphSpacing ?? 0) + (NSLocationInRange(index, line) ? extra : 0)
    }
}
