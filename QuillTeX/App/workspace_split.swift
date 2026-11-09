import AppKit

/// A wider grab region needs its own hover feedback above the neighboring
/// text/PDF views, whose cursor regions otherwise compete with the thin divider.
final class WorkspaceDividerView: NSSplitView {
    private var dividerTrackingAreas: [NSTrackingArea] = []
    private var hoveredDivider: Int?
    var blocksDraggingWhileLeadingScrollerVisible = false

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
            let rect = drawnRect.insetBy(dx: -12, dy: 0).intersection(bounds)
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

    override func mouseDown(with event: NSEvent) {
        // Recheck at mouse-down: an overlay scrollbar may appear after hover.
        guard !(0..<max(0, subviews.count - 1)).contains(where: isDividerDragBlocked) else { return }
        super.mouseDown(with: event)
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

    override func drawDivider(in rect: NSRect) {
        // The window is non-opaque so the sidebar can show the desktop behind it.
        // Paint the divider itself opaque, or the desktop shows through this line.
        NSColor(white: 0.90, alpha: 1).setFill()
        rect.fill()
        guard let index = hoveredDivider, !isDividerDragBlocked(at: index), subviews.indices.contains(index),
              abs(rect.midX - (subviews[index].frame.maxX + dividerThickness / 2)) < 1 else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
        NSRect(x: rect.midX - 1.5, y: rect.minY, width: 3, height: rect.height).fill()
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
        let nativeRect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                        forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        // Keep AppKit's collapsed-pane rules while making visible thin dividers
        // easy to catch from either neighboring pane (25 points overall).
        guard !nativeRect.isEmpty else { return nativeRect }
        return drawnRect.insetBy(dx: -12, dy: 0).intersection(splitView.bounds)
    }
}

/// The editor/PDF divider belongs to an inner split, so it cannot resize the sidebar.
final class WorkspaceContentSplitController: WorkspacePaneSplitController {
    private var mode = PaneMode.split
    private var balancePending = true
    var restoredFraction: Double?
    var onLayoutChange: (() -> Void)?

    init(editor: NSViewController, preview: NSViewController) {
        super.init()
        (splitView as? WorkspaceDividerView)?.blocksDraggingWhileLeadingScrollerVisible = true
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
        balanceIfNeeded()
    }

    private func balanceIfNeeded() {
        if balancePending, mode == .split, splitView.bounds.width > 520 {
            balancePending = false
            let fraction = restoredFraction ?? 0.5
            restoredFraction = nil
            splitView.setPosition((splitView.bounds.width - splitView.dividerThickness) * fraction, ofDividerAt: 0)
        }
    }
    var editorFraction: Double {
        let width = splitView.bounds.width - splitView.dividerThickness
        guard mode == .split, width > 0 else { return 0.5 }
        return splitViewItems[0].viewController.view.frame.width / width
    }
    @objc private func splitResized() { if !balancePending, mode == .split { onLayoutChange?() } }
    func restoreFraction(_ fraction: Double) {
        restoredFraction = fraction
        balancePending = true
        balanceIfNeeded()
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
            if equalize { restoredFraction = nil }
            balancePending = true
            view.layoutSubtreeIfNeeded()
            balanceIfNeeded()
        }
    }
}

final class WorkspaceSplitController: WorkspacePaneSplitController {
    let content: WorkspaceContentSplitController
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
        contentColumn.view.addSubview(topBar.view)
        contentColumn.view.addSubview(content.view)
        topBar.view.translatesAutoresizingMaskIntoConstraints = false
        content.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.view.topAnchor.constraint(equalTo: contentColumn.view.topAnchor),
            topBar.view.leadingAnchor.constraint(equalTo: contentColumn.view.leadingAnchor),
            topBar.view.trailingAnchor.constraint(equalTo: contentColumn.view.trailingAnchor),
            topBar.view.heightAnchor.constraint(equalToConstant: topBarHeight),
            content.view.topAnchor.constraint(equalTo: topBar.view.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: contentColumn.view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: contentColumn.view.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: contentColumn.view.bottomAnchor)
        ])
        let contentItem = NSSplitViewItem(viewController: contentColumn)
        contentItem.minimumThickness = 520
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        content.onLayoutChange = { [weak self] in self?.reportLayout() }
        NotificationCenter.default.addObserver(self, selector: #selector(splitResized), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
