import AppKit
import SwiftUI

/// Geometry shared by chrome hit testing, hover feedback and edge guards.
/// Mirrors PaperLens 1.0.3 so both apps behave the same in the title row.
enum ChromeHitShape {
    static func contains(_ point: NSPoint, in bounds: NSRect) -> Bool {
        guard bounds.contains(point) else { return false }
        return NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                            yRadius: bounds.height / 2).contains(point)
    }
}

/// Controls own their entire rectangular slot. The corners are inert, rather
/// than holes through which AppKit can interpret a double click as titlebar zoom.
struct ChromeEventBarrier: NSViewRepresentable {
    var cornersOnly = false
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> ChromeEventBarrierView { ChromeEventBarrierView() }
    func updateNSView(_ view: ChromeEventBarrierView, context: Context) {
        view.cornersOnly = cornersOnly
        view.isControlEnabled = isEnabled
    }
}

final class ChromeEventBarrierView: NSView {
    var cornersOnly = false
    var isControlEnabled = true
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local) else { return nil }
        return cornersOnly && ChromeHitShape.contains(local, in: bounds) ? nil : self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
}

extension View {
    /// Apply AFTER the group padding, so separators and padding are protected too.
    func chromeControlGroup() -> some View {
        background(ChromeEventBarrier()).accessibilityElement(children: .contain)
    }
    func chromeControlBoundary() -> some View {
        background(ChromeEventBarrier())
            .overlay(ChromeEventBarrier(cornersOnly: true).accessibilityHidden(true))
    }
}

struct ChromeButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.primaryInk.opacity(isEnabled ? 1 : 0.3))
            .background(Capsule().fill(Palette.primaryInk.opacity(
                isEnabled && configuration.isPressed ? Palette.pressedOpacity :
                    (selected ? Palette.selectedOpacity : 0))))
            .contentShape(Capsule())
    }
}

/// Hover feedback for the controls living in the title row. SwiftUI's `onHover`
/// does not fire reliably inside that hosting view (the same reason PaperLens
/// 1.0.3 moved to an AppKit tracker), so the highlight is drawn by a tracking
/// overlay that reads the real pointer position and never takes clicks.
struct ChromeHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.overlay(ChromeHoverTracker(isEnabled: isEnabled).allowsHitTesting(false))
    }
}

private struct ChromeHoverTracker: NSViewRepresentable {
    let isEnabled: Bool
    func makeNSView(context: Context) -> ChromeHoverView { ChromeHoverView() }
    func updateNSView(_ view: ChromeHoverView, context: Context) {
        view.isControlEnabled = isEnabled
        view.refreshHover()
    }
    static func dismantleNSView(_ view: ChromeHoverView, coordinator: ()) {
        view.isControlEnabled = false
        view.refreshHover()
    }
}

final class ChromeHoverView: NSView {
    var isControlEnabled = true
    private var area: NSTrackingArea?
    private var mouseMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }
    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        refreshHover()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(next)
        area = next
        refreshHover()
    }
    // AppKit can synthesize an entry during initial layout; validate the pointer.
    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func mouseMoved(with event: NSEvent) { refreshHover() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        setHover(false)
        guard let window else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.refreshHover()
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHover() }
            })
        }
        refreshHover()
    }
    override func viewDidHide() { super.viewDidHide(); setHover(false) }
    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }
    func refreshHover() {
        guard isControlEnabled, let window, !isHiddenOrHasHiddenAncestor, window.isKeyWindow, NSApp.isActive else { setHover(false); return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        setHover(!visibleRect.isEmpty && visibleRect.contains(point) && ChromeHitShape.contains(point, in: bounds))
    }
    private func setHover(_ value: Bool) {
        // Replace the layer colour, including clearing it: a transparent overlay
        // that merely skips drawing would keep its previous hover pixels.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = value ? NSColor.black.withAlphaComponent(Palette.chromeHoverOpacity).cgColor : nil
        CATransaction.commit()
    }
}

/// SwiftUI's outer hosting view can return itself for transparent control edges,
/// bypassing representable backgrounds. Route the title row at its hosting
/// boundary, before those clicks reach NSThemeFrame's double-click handling.
struct ChromeHostingContainer<Content: View>: NSViewRepresentable {
    let content: Content
    func makeNSView(context: Context) -> ChromeHostingView<Content> { ChromeHostingView(rootView: content) }
    func updateNSView(_ view: ChromeHostingView<Content>, context: Context) { view.rootView = content }
}

final class ChromeHostingView<Content: View>: NSHostingView<Content> {
    private let blankArea = ChromeBlankDragView()
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: Content) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        addSubview(blankArea)
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        blankArea.frame = bounds
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), !isHiddenOrHasHiddenAncestor else { return nil }
        let guards = barrierViews(in: self)
        // Circular controls win over their enclosing group. SwiftUI owns the
        // action; the barriers only keep the gaps from reaching the titlebar.
        if guards.contains(where: { view in
            view.cornersOnly && view.isControlEnabled && !view.isHiddenOrHasHiddenAncestor
                && ChromeHitShape.contains(view.convert(local, from: self), in: view.bounds)
        }) {
            let target = super.hitTest(point)
            return target is ChromeEventBarrierView ? self : (target ?? self)
        }
        if let barrier = guards.last(where: { view in
            !view.isHiddenOrHasHiddenAncestor && view.bounds.contains(view.convert(local, from: self))
        }) { return barrier }
        return blankArea
    }
    private func barrierViews(in view: NSView) -> [ChromeEventBarrierView] {
        view.subviews.flatMap { child in
            if let barrier = child as? ChromeEventBarrierView { return [barrier] }
            return barrierViews(in: child)
        }
    }
}

private final class ChromeBlankDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
