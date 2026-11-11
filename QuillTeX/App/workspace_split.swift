import AppKit

/// The sidebar/content divider lives on the shared backdrop; the editor/PDF
/// divider lives inside the white card. Each split declares which one it owns,
/// because `drawDivider` cannot tell them apart by itself.
enum WorkspaceDividerAppearance {
    /// No resting line: the sidebar and the content column share one continuous
    /// backdrop, so a visible line there would break the surface apart.
    case sharedBackground
    /// A subtle hairline that reads against the white card.
    case cardHairline
}

/// A wider grab region needs its own hover feedback above the neighboring
/// text/PDF views, whose cursor regions otherwise compete with the thin divider.
final class WorkspaceDividerView: NSSplitView {
    private var dividerTrackingAreas: [NSTrackingArea] = []
    private var hoveredDivider: Int?
    var blocksDraggingWhileLeadingScrollerVisible = false
    var dividerAppearance: WorkspaceDividerAppearance = .sharedBackground

    /// The fill under the hover/drag accent. The outer split is clear so the
    /// sidebar and content keep one unbroken backdrop.
    var restingDividerColor: NSColor {
        switch dividerAppearance {
        case .sharedBackground: return .clear
        case .cardHairline: return NSColor(white: 0.92, alpha: 1)
        }
    }

    func isDividerDragBlocked(at index: Int) -> Bool {
        guard blocksDraggingWhileLeadingScrollerVisible, subviews.indices.contains(index) else { return false }
        func hasVisibleScroller(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { return false }
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller,
               let scroller = scroll.verticalScroller, !scroller.isHiddenOrHasHiddenAncestor {
                let knob = scroller.rect(for: .knob)
                // Overlay scrollers retain alphaValue == 1 even after fading out.
                // Native hit testing follows the actual visible/interactive knob.
                if !knob.isEmpty,
                   scroller.hitTest(scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: scroller.superview)) != nil {
                    return true
                }
            }
            return view.subviews.contains(where: hasVisibleScroller)
        }
        return hasVisibleScroller(subviews[index])
    }

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    /// The delegate's effective rect is also AppKit's native drag region.
    /// Use it for hit testing and cursors so child editor/PDF cursor regions
    /// cannot take ownership of either side of the visible divider.
    var effectiveDividerRects: [(index: Int, rect: NSRect)] {
        dividerTrackingRects.filter { !isDividerDragBlocked(at: $0.index) }
    }

    private var dividerTrackingRects: [(index: Int, rect: NSRect)] {
        guard subviews.count > 1 else { return [] }
        return (0..<(subviews.count - 1)).compactMap { index in
            guard !subviews[index].isHidden, !subviews[index + 1].isHidden,
                  subviews[index].frame.width > 0, subviews[index + 1].frame.width > 0 else { return nil }
            let drawnRect = NSRect(x: subviews[index].frame.maxX, y: bounds.minY,
                                   width: dividerThickness, height: bounds.height)
            // Always a 25 pt grab band, centred on the divider, even when the
            // outer split has no visible gap at all.
            let rect = NSRect(x: drawnRect.midX - 12.5, y: bounds.minY,
                              width: 25, height: bounds.height).intersection(bounds)
            return rect.isEmpty ? nil : (index, rect)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard effectiveDividerRects.contains(where: { $0.rect.contains(localPoint) }) else {
            return super.hitTest(point)
        }
        if let hit = super.hitTest(point), hit is NSScroller { return hit }
        return self
    }

    /// True while AppKit is running a divider's tracking loop. Window resizes use
    /// this to tell a user-chosen ratio apart from AppKit reallocating width.
    private(set) var isDraggingDivider = false

    override func mouseDown(with event: NSEvent) {
        // Recheck at mouse-down: an overlay scrollbar may appear after hover.
        guard !(0..<max(0, subviews.count - 1)).contains(where: isDividerDragBlocked) else { return }
        isDraggingDivider = true
        super.mouseDown(with: event)
        isDraggingDivider = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        for divider in effectiveDividerRects { addCursorRect(divider.rect, cursor: .resizeLeftRight) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in dividerTrackingAreas { removeTrackingArea(area) }
        dividerTrackingAreas.removeAll()
        // Keep tracking the edge while the scrollbar fades, then re-evaluate
        // drag availability on movement instead of leaving a stale cursor region.
        for divider in dividerTrackingRects {
            let area = NSTrackingArea(rect: divider.rect,
                                     options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .enabledDuringMouseDrag],
                                     owner: self, userInfo: ["divider": divider.index])
            addTrackingArea(area)
            dividerTrackingAreas.append(area)
        }
        if let hoveredDivider, !effectiveDividerRects.contains(where: { $0.index == hoveredDivider }) {
            self.hoveredDivider = nil
            needsDisplay = true
        }
        window?.invalidateCursorRects(for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = effectiveDividerRects.first(where: { $0.rect.contains(point) }) else {
            hoveredDivider = nil
            needsDisplay = true
            if blocksDraggingWhileLeadingScrollerVisible, isDividerDragBlocked(at: 0) {
                NSCursor.arrow.set()
                return
            }
            super.mouseMoved(with: event)
            return
        }
        if hoveredDivider != divider.index { hoveredDivider = divider.index; needsDisplay = true }
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["divider"] as? Int else {
            super.mouseEntered(with: event); return
        }
        guard !isDividerDragBlocked(at: index) else { NSCursor.arrow.set(); return }
        hoveredDivider = index
        needsDisplay = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["divider"] != nil else { super.mouseExited(with: event); return }
        hoveredDivider = nil
        needsDisplay = true
        window?.resetCursorRects()
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard effectiveDividerRects.contains(where: { $0.rect.contains(point) }) else {
            if blocksDraggingWhileLeadingScrollerVisible, isDividerDragBlocked(at: 0) {
                NSCursor.arrow.set()
                return
            }
            super.cursorUpdate(with: event); return
        }
        NSCursor.resizeLeftRight.set()
    }

    /// The sidebar and content share one continuous backdrop, so the outer split
    /// has no divider gap at all: a one-point transparent channel between the two
    /// items let a hairline of desktop through. The inner editor/PDF split keeps
    /// its hairline thickness.
    override var dividerThickness: CGFloat { dividerGap }

    var dividerGap: CGFloat = 1

    override func drawDivider(in rect: NSRect) {
        // The window is non-opaque, so a painted line would otherwise be needed
        // to keep the desktop from showing through. The sidebar and content now
        // share one backdrop, so the outer divider rests clear; the inner divider
        // paints its hairline on the white card instead.
        let resting = restingDividerColor
        if resting.alphaComponent > 0 {
            resting.setFill()
            rect.fill()
        }
        guard let index = hoveredDivider, !isDividerDragBlocked(at: index), subviews.indices.contains(index),
              abs(rect.midX - (subviews[index].frame.maxX + dividerThickness / 2)) < 1 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
        NSRect(x: rect.midX - 1.5, y: rect.minY, width: 3, height: rect.height).fill()
    }
}

/// The content column's backdrop. It mirrors `SidebarBackdrop` from
/// surface_styles.swift: the same behind-window sidebar material under a light
/// white veil, or an opaque light gray surface when the system reduces
/// transparency. The top bar and the white editor card are layered on top.
final class WorkspaceBackdropView: NSVisualEffectView {
    static let whiteVeil = NSColor.white.withAlphaComponent(0.25)
    /// Matches `Palette.sidebarSurface` used for the opaque sidebar variant.
    static let opaqueSurface = NSColor(white: 0.945, alpha: 1)

    let veilView = NSView()
    private var accessibilityObserver: NSObjectProtocol?

    /// AppKit counterpart of SwiftUI's `accessibilityReduceTransparency`.
    var reducesTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var veilColor: NSColor { reducesTransparency ? Self.opaqueSurface : Self.whiteVeil }

    init() {
        super.init(frame: .zero)
        configure()
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        material = .sidebar
        blendingMode = .behindWindow
        state = .active
        isEmphasized = false
        veilView.wantsLayer = true
        veilView.autoresizingMask = [.width, .height]
        veilView.frame = bounds
        addSubview(veilView)
        updateVeil()
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in self?.updateVeil() }
    }

    override func layout() {
        super.layout()
        veilView.frame = bounds
    }

    func updateVeil() {
        veilView.layer?.backgroundColor = veilColor.cgColor
        needsDisplay = true
    }

    /// Purely decorative: the backdrop must never take clicks from the panes
    /// or from the divider grab regions above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit {
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
    }
}

class WorkspacePaneSplitController: NSSplitViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        splitView = WorkspaceDividerView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        if let divider = splitView as? WorkspaceDividerView, divider.isDividerDragBlocked(at: dividerIndex) {
            return .zero
        }
        // Keep AppKit's collapsed-pane rules while making visible thin dividers
        // easy to catch from either neighboring pane (25 points overall). A zero
        // thickness divider (the shared-background outer split) has no native
        // rect, so its band is provided directly.
        let band = NSRect(x: drawnRect.midX - 12.5, y: drawnRect.minY,
                          width: 25, height: drawnRect.height).intersection(splitView.bounds)
        if splitView.dividerThickness <= 0 { return band }
        let nativeRect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                        forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        guard !nativeRect.isEmpty else { return nativeRect }
        return band
    }
}

/// The editor/PDF divider belongs to an inner split, so it cannot resize the sidebar.
final class WorkspaceContentSplitController: WorkspacePaneSplitController {
    private var mode = PaneMode.split
    private var balancePending = true
    /// Ratio the user chose. Re-applied whenever the split gets a new width, so a
    /// window that grows after the workspace opens keeps the same proportions
    /// instead of handing the extra width to both panes equally.
    private var targetFraction: Double = 0.5
    private var lastLayoutWidth: CGFloat = 0
    var onLayoutChange: (() -> Void)?

    init(editor: NSViewController, preview: NSViewController) {
        super.init()
        // With the editor's scrollbar on screen, the divider pauses; its own grab
        // band would otherwise capture the scrollbar's edge.
        (splitView as? WorkspaceDividerView)?.blocksDraggingWhileLeadingScrollerVisible = true
        // This divider sits inside the white card, so it paints a subtle hairline
        // instead of the outer split's clear resting line.
        (splitView as? WorkspaceDividerView)?.dividerAppearance = .cardHairline
        for controller in [editor, preview] {
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 260
            item.canCollapse = true
            addSplitViewItem(item)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = splitView.bounds.width
        if balancePending {
            balanceIfNeeded()
            lastLayoutWidth = width
            return
        }
        if mode == .split, width > 520,
           abs(width - lastLayoutWidth) > 0.5,
           (splitView as? WorkspaceDividerView)?.isDraggingDivider != true {
            setPosition(for: targetFraction)
        }
        lastLayoutWidth = width
    }

    private func setPosition(for fraction: Double) {
        guard mode == .split, splitView.bounds.width > 520 else { return }
        let available = splitView.bounds.width - splitView.dividerThickness
        splitView.setPosition(available * fraction, ofDividerAt: 0)
    }

    private func balanceIfNeeded() {
        guard balancePending, mode == .split, splitView.bounds.width > 520 else { return }
        balancePending = false
        setPosition(for: targetFraction)
    }
    var editorFraction: Double {
        let width = splitView.bounds.width - splitView.dividerThickness
        guard mode == .split, width > 0 else { return targetFraction }
        return splitViewItems[0].viewController.view.frame.width / width
    }
    @objc private func splitResized() {
        guard !balancePending, mode == .split else { return }
        if (splitView as? WorkspaceDividerView)?.isDraggingDivider == true {
            targetFraction = editorFraction
        }
        onLayoutChange?()
    }
    func restoreFraction(_ fraction: Double) {
        targetFraction = fraction.isFinite ? min(0.85, max(0.15, fraction)) : 0.5
        balancePending = true
        balanceIfNeeded()
        lastLayoutWidth = splitView.bounds.width
    }

    func update(mode newMode: PaneMode, equalize: Bool) {
        guard newMode != mode || equalize else { return }
        if newMode != .preview { splitViewItems[0].isCollapsed = false }
        if newMode != .editor { splitViewItems[1].isCollapsed = false }
        if newMode == .preview { splitViewItems[0].isCollapsed = true }
        if newMode == .editor { splitViewItems[1].isCollapsed = true }
        mode = newMode
        splitView.adjustSubviews()
        if newMode == .split {
            if equalize { targetFraction = 0.5 }
            balancePending = true
            view.layoutSubtreeIfNeeded()
            balanceIfNeeded()
        }
        lastLayoutWidth = splitView.bounds.width
    }
}

/// The editor/PDF workspace insets its content into a white rounded card;
/// the document browser sits directly on the shared backdrop instead.
enum WorkspaceCardStyle {
    case document
    case library
}

final class WorkspaceSplitController: WorkspacePaneSplitController {
    /// Inset of the white card inside the content column.
    static let cardInset: CGFloat = 8
    static let cardCornerRadius: CGFloat = 16

    let content: WorkspaceContentSplitController
    /// The card container for the editor/PDF split. It is white and rounded for
    /// a document, and fully transparent edge to edge for the library browser.
    let cardView: NSView = {
        let card = NSView()
        card.wantsLayer = true
        return card
    }()
    /// The shared backdrop behind the top bar and the card, in both styles.
    let backdropView = WorkspaceBackdropView()
    private(set) var cardStyle: WorkspaceCardStyle = .document
    private var cardLeadingConstraint: NSLayoutConstraint!
    private var cardTrailingConstraint: NSLayoutConstraint!
    private var cardBottomConstraint: NSLayoutConstraint!
    private var initialized = false
    private var previousSidebar = true
    private var previousSplitLayoutVersion = 0
    private var sidebarWidth: CGFloat = 248
    private var savedEditorFraction: Double = 0.5
    var onLayoutChange: ((Double, Double) -> Void)?
    /// Reports a collapse caused by dragging the divider, not by the sidebar toggle.
    var onSidebarVisibilityChange: ((Bool) -> Void)?
    private var reportingLayout = false
    private var layoutReportPending = false
    private var sidebarAnimating = false
    private var sidebarAnimationGeneration = 0

    init(sidebar: NSViewController, topBar: NSViewController, editor: NSViewController, preview: NSViewController,
         topBarHeight: CGFloat) {
        content = WorkspaceContentSplitController(editor: editor, preview: preview)
        super.init()
        // Both middle dividers pause while the pane beside them shows a scrollbar.
        (splitView as? WorkspaceDividerView)?.blocksDraggingWhileLeadingScrollerVisible = true
        // The sidebar and the content column share one backdrop, so their divider
        // rests clear and only shows the accent while hovered or dragged.
        (splitView as? WorkspaceDividerView)?.dividerAppearance = .sharedBackground
        (splitView as? WorkspaceDividerView)?.dividerGap = 0
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        // Preserve sidebar width, but stay below AppKit's drag priority (490)
        // so the sidebar divider remains freely adjustable.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 450)
        let contentColumn = NSViewController()
        contentColumn.view = NSView()
        contentColumn.addChild(topBar)
        contentColumn.addChild(content)
        let column = contentColumn.view
        // Back to front: shared backdrop, transparent top bar, white rounded card.
        column.addSubview(backdropView)
        column.addSubview(topBar.view)
        column.addSubview(cardView)
        cardView.addSubview(content.view)
        topBar.view.translatesAutoresizingMaskIntoConstraints = false
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        cardView.translatesAutoresizingMaskIntoConstraints = false
        content.view.translatesAutoresizingMaskIntoConstraints = false
        cardLeadingConstraint = cardView.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: WorkspaceSplitController.cardInset)
        cardTrailingConstraint = cardView.trailingAnchor.constraint(equalTo: column.trailingAnchor, constant: -WorkspaceSplitController.cardInset)
        cardBottomConstraint = cardView.bottomAnchor.constraint(equalTo: column.bottomAnchor, constant: -WorkspaceSplitController.cardInset)
        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: column.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: column.bottomAnchor),

            topBar.view.topAnchor.constraint(equalTo: column.topAnchor),
            topBar.view.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            topBar.view.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            topBar.view.heightAnchor.constraint(equalToConstant: topBarHeight),

            cardLeadingConstraint,
            cardTrailingConstraint,
            cardBottomConstraint,
            cardView.topAnchor.constraint(equalTo: topBar.view.bottomAnchor),

            // The editor/PDF split fills the card edge to edge, so collapsing one
            // pane (Editor Only / PDF Only) never moves the card or its insets.
            content.view.topAnchor.constraint(equalTo: cardView.topAnchor),
            content.view.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: cardView.bottomAnchor)
        ])
        applyCardStyle()
        let contentItem = NSSplitViewItem(viewController: contentColumn)
        contentItem.minimumThickness = 520
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        content.onLayoutChange = { [weak self] in self?.reportLayout() }
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Switch between the inset white document card and the edge-to-edge library
    /// browser surface. The shared backdrop stays behind both.
    func setCardStyle(_ style: WorkspaceCardStyle) {
        guard style != cardStyle else { return }
        cardStyle = style
        applyCardStyle()
    }

    private func applyCardStyle() {
        let inset = cardStyle == .library ? 0 : WorkspaceSplitController.cardInset
        cardLeadingConstraint.constant = inset
        cardTrailingConstraint.constant = -inset
        cardBottomConstraint.constant = -inset
        switch cardStyle {
        case .document:
            cardView.layer?.backgroundColor = NSColor.white.cgColor
            cardView.layer?.cornerRadius = WorkspaceSplitController.cardCornerRadius
            cardView.layer?.cornerCurve = .continuous
            cardView.layer?.masksToBounds = true
        case .library:
            // The browser draws straight on the backdrop: no white surface, no
            // rounding and no clipping between the top bar and the window edges.
            cardView.layer?.backgroundColor = NSColor.clear.cgColor
            cardView.layer?.cornerRadius = 0
            cardView.layer?.cornerCurve = .circular
            cardView.layer?.masksToBounds = false
        }
        cardView.needsLayout = true
        cardView.superview?.needsLayout = true
    }

    func restoreLayout(sidebarWidth width: Double, editorFraction fraction: Double) {
        sidebarWidth = width.isFinite ? min(400, max(180, width)) : 248
        savedEditorFraction = fraction.isFinite ? min(0.85, max(0.15, fraction)) : 0.5
        reportingLayout = true
        if initialized, previousSidebar { splitView.setPosition(sidebarWidth, ofDividerAt: 0) }
        content.restoreFraction(savedEditorFraction)
        reportingLayout = false
    }
    @objc private func splitResized() { reportLayout() }
    private func reportLayout() {
        guard initialized, !reportingLayout, !layoutReportPending, !sidebarAnimating else { return }
        layoutReportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutReportPending = false
            guard !self.sidebarAnimating else { return }
            // Dragging the divider all the way left collapses the split item
            // without going through the toggle; keep the store in sync so the
            // top bar switches to its collapsed layout.
            let collapsed = self.splitViewItems[0].isCollapsed
            if self.previousSidebar == collapsed {
                self.previousSidebar = !collapsed
                self.onSidebarVisibilityChange?(!collapsed)
            }
            if self.previousSidebar, !collapsed {
                self.sidebarWidth = self.splitViewItems[0].viewController.view.frame.width
            }
            if !self.content.splitViewItems.contains(where: \.isCollapsed) { self.savedEditorFraction = self.content.editorFraction }
            self.onLayoutChange?(self.sidebarWidth, self.savedEditorFraction)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !initialized, splitView.bounds.width > sidebarWidth + 520 + splitView.dividerThickness {
            initialized = true
            if previousSidebar {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.previousSidebar else { return }
                    self.splitView.setPosition(self.sidebarWidth, ofDividerAt: 0)
                }
            }
        }
    }

    func update(sidebarVisible: Bool, paneMode: PaneMode, splitLayoutVersion: Int) {
        if previousSidebar != sidebarVisible {
            if previousSidebar && !sidebarAnimating { sidebarWidth = splitViewItems[0].viewController.view.frame.width }
            previousSidebar = sidebarVisible
            sidebarAnimationGeneration += 1
            let generation = sidebarAnimationGeneration
            let animate = initialized && view.window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            sidebarAnimating = animate
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animate ? 0.28 : 0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if animate { splitViewItems[0].animator().isCollapsed = !sidebarVisible }
                else { splitViewItems[0].isCollapsed = !sidebarVisible }
            } completionHandler: { [weak self] in
                guard let self, self.sidebarAnimationGeneration == generation else { return }
                self.sidebarAnimating = false
                if self.previousSidebar { self.splitView.setPosition(self.sidebarWidth, ofDividerAt: 0) }
                self.reportLayout()
            }
            if !animate {
                splitView.adjustSubviews()
                if sidebarVisible { splitView.setPosition(sidebarWidth, ofDividerAt: 0) }
            }
        }
        let equalize = previousSplitLayoutVersion != splitLayoutVersion
        previousSplitLayoutVersion = splitLayoutVersion
        content.update(mode: paneMode, equalize: equalize)
    }
}
