import AppKit

/// A wider grab region needs its own hover feedback above the neighboring
/// text/PDF views, whose cursor regions otherwise compete with the thin divider.
final class WorkspaceDividerView: NSSplitView {
    private var dividerTrackingAreas: [NSTrackingArea] = []
    private var hoveredDivider: Int?

    override func layout() {
        super.layout()
        updateTrackingAreas()
    }

    /// The delegate's effective rect is also AppKit's native drag region.
    /// Use it for hit testing and cursors so child editor/PDF cursor regions
    /// cannot take ownership of either side of the visible divider.
    var effectiveDividerRects: [(index: Int, rect: NSRect)] {
        guard subviews.count > 1 else { return [] }
        return (0..<(subviews.count - 1)).compactMap { index in
            guard !subviews[index].isHidden, !subviews[index + 1].isHidden,
                  subviews[index].frame.width > 0, subviews[index + 1].frame.width > 0 else { return nil }
            let drawnRect = NSRect(x: subviews[index].frame.maxX, y: bounds.minY,
                                   width: dividerThickness, height: bounds.height)
            let rect = (delegate?.splitView?(self, effectiveRect: drawnRect,
                                            forDrawnRect: drawnRect, ofDividerAt: index) ?? drawnRect).intersection(bounds)
            return rect.isEmpty ? nil : (index, rect)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if effectiveDividerRects.contains(where: { $0.rect.contains(localPoint) }) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for divider in effectiveDividerRects { addCursorRect(divider.rect, cursor: .resizeLeftRight) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in dividerTrackingAreas { removeTrackingArea(area) }
        dividerTrackingAreas.removeAll()
        for divider in effectiveDividerRects {
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
            super.cursorUpdate(with: event); return
        }
        NSCursor.resizeLeftRight.set()
    }

    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: rect)
        guard let index = hoveredDivider, subviews.indices.contains(index),
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

    init(editor: NSViewController, preview: NSViewController) {
        super.init()
        for controller in [editor, preview] {
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 260
            item.canCollapse = true
            addSplitViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLayout() {
        super.viewDidLayout()
        balanceIfNeeded()
    }

    private func balanceIfNeeded() {
        if balancePending, mode == .split, splitView.bounds.width > 520 {
            balancePending = false
            splitView.setPosition((splitView.bounds.width - splitView.dividerThickness) / 2, ofDividerAt: 0)
        }
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
            balancePending = true
            view.layoutSubtreeIfNeeded()
            balanceIfNeeded()
        }
    }
}

final class WorkspaceSplitController: WorkspacePaneSplitController {
    let content: WorkspaceContentSplitController
    private var tabBarHeight: NSLayoutConstraint?
    private var tabBarController: NSViewController?
    private var initialized = false
    private var previousSidebar = true
    private var previousSplitLayoutVersion = 0
    private var sidebarWidth: CGFloat = 240

    init(sidebar: NSViewController, editor: NSViewController, preview: NSViewController, tabBar: NSViewController? = nil) {
        content = WorkspaceContentSplitController(editor: editor, preview: preview)
        super.init()
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        // Preserve sidebar width, but stay below AppKit's drag priority (490)
        // so the sidebar divider remains freely adjustable.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 450)
        let contentColumn: NSViewController
        if let tabBar {
            let column = NSViewController()
            column.view = NSView()
            column.addChild(tabBar); column.addChild(content)
            column.view.addSubview(tabBar.view); column.view.addSubview(content.view)
            tabBar.view.translatesAutoresizingMaskIntoConstraints = false
            content.view.translatesAutoresizingMaskIntoConstraints = false
            let height = tabBar.view.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                tabBar.view.topAnchor.constraint(equalTo: column.view.topAnchor),
                tabBar.view.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
                tabBar.view.trailingAnchor.constraint(equalTo: column.view.trailingAnchor), height,
                content.view.topAnchor.constraint(equalTo: tabBar.view.bottomAnchor),
                content.view.leadingAnchor.constraint(equalTo: column.view.leadingAnchor),
                content.view.trailingAnchor.constraint(equalTo: column.view.trailingAnchor),
                content.view.bottomAnchor.constraint(equalTo: column.view.bottomAnchor)
            ])
            tabBarHeight = height
            tabBarController = tabBar
            contentColumn = column
        } else { contentColumn = content }
        let contentItem = NSSplitViewItem(viewController: contentColumn)
        contentItem.minimumThickness = 520
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

    func update(sidebarVisible: Bool, paneMode: PaneMode, splitLayoutVersion: Int, showTabs: Bool = false) {
        tabBarHeight?.constant = showTabs ? 32 : 0
        tabBarController?.view.isHidden = !showTabs
        if previousSidebar != sidebarVisible {
            if previousSidebar { sidebarWidth = splitViewItems[0].viewController.view.frame.width }
            splitViewItems[0].isCollapsed = !sidebarVisible
            previousSidebar = sidebarVisible
            splitView.adjustSubviews()
            if sidebarVisible { splitView.setPosition(sidebarWidth, ofDividerAt: 0) }
        }
        let equalize = previousSplitLayoutVersion != splitLayoutVersion
        previousSplitLayoutVersion = splitLayoutVersion
        content.update(mode: paneMode, equalize: equalize)
    }
}
