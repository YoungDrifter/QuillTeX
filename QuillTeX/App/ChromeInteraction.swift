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
    var selectionNamespace: Namespace.ID? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chromeSegmentedNamespace) private var segmentedNamespace
    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        let groupedSelection = selectionNamespace != nil && selectionNamespace == segmentedNamespace
        configuration.label
            .foregroundStyle((selected ? Color.white : Palette.primaryInk).opacity(isEnabled ? 1 : 0.3))
            .background {
                if selected && !groupedSelection {
                    ChromeSelectionSurface(pressed: pressed)
                        .modifier(ChromeSelectionMotion(namespace: selectionNamespace))
                        .padding(ChromeMetrics.buttonSurfaceInset)
                        .opacity(isEnabled ? 1 : 0.35)
                } else if pressed && !selected {
                    Capsule().fill(Palette.primaryInk.opacity(0.08)).padding(ChromeMetrics.buttonSurfaceInset)
                }
            }
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : ChromeMotion.press, value: configuration.isPressed)
            .animation(reduceMotion ? nil : ChromeMotion.press, value: selected)
            .anchorPreference(key: ChromeSelectionBoundsKey.self, value: .bounds) { bounds in
                selected && groupedSelection ? ChromeSelectionBounds(bounds: bounds, pressed: pressed, enabled: isEnabled) : nil
            }
    }
}

private struct ChromeSelectionSurface: View {
    var pressed = false
    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(white: pressed ? 0.12 : 0.27), Color(white: pressed ? 0.08 : 0.12)],
                startPoint: .top, endPoint: .bottom))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.4), .black.opacity(0.25)],
                startPoint: .top, endPoint: .bottom), lineWidth: 0.7))
    }
}

private struct ChromeSegmentedNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
private extension EnvironmentValues {
    var chromeSegmentedNamespace: Namespace.ID? {
        get { self[ChromeSegmentedNamespaceKey.self] }
        set { self[ChromeSegmentedNamespaceKey.self] = newValue }
    }
}
private struct ChromeSelectionBounds {
    let bounds: Anchor<CGRect>
    let pressed: Bool
    let enabled: Bool
}
private struct ChromeSelectionBoundsKey: PreferenceKey {
    static let defaultValue: ChromeSelectionBounds? = nil
    static func reduce(value: inout ChromeSelectionBounds?, nextValue: () -> ChromeSelectionBounds?) {
        value = nextValue() ?? value
    }
}

private struct ChromeSelectionMotion: ViewModifier {
    var namespace: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder func body(content: Content) -> some View {
        if let namespace, !reduceMotion { content.matchedGeometryEffect(id: "selection", in: namespace) }
        else { content }
    }
}

/// One persistent selection surface belongs to the group, not to its buttons.
/// Moving its frame avoids the insertion/removal fades of per-button backgrounds.
struct ChromeSegmentedGroup<Selection: Equatable, Content: View>: View {
    let selection: Selection
    @ViewBuilder let content: (Namespace.ID) -> Content
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: ChromeMetrics.chromeSpacing) { content(namespace) }
            .environment(\.chromeSegmentedNamespace, namespace)
            .backgroundPreferenceValue(ChromeSelectionBoundsKey.self) { selected in
                GeometryReader { geometry in
                    if let selected {
                        let frame = geometry[selected.bounds].insetBy(dx: ChromeMetrics.buttonSurfaceInset, dy: ChromeMetrics.buttonSurfaceInset)
                        ChromeSelectionSurface(pressed: selected.pressed)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .opacity(selected.enabled ? 1 : 0.35)
                            .animation(reduceMotion ? nil : ChromeMotion.press, value: frame)
                            .animation(reduceMotion ? nil : ChromeMotion.press, value: selected.pressed)
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

/// Hover feedback for the controls living in the title row. SwiftUI's `onHover`
/// does not fire reliably inside that hosting view (the same reason PaperLens
/// 1.0.3 moved to an AppKit tracker). The tracker only reports pointer changes;
/// hover moves the glyph and reveals a short rule, without drawing a surface.
struct ChromeHoverFeedback: ViewModifier {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.primaryInk.opacity(0.7))
                    .frame(width: 10, height: 1.5).padding(.bottom, 2)
                    .opacity(hovered && !selected ? 1 : 0).allowsHitTesting(false)
            }
            .scaleEffect(hovered && !reduceMotion ? 1.055 : 1)
            .offset(y: hovered && !reduceMotion ? -0.75 : 0)
            .background(ChromeHoverTracker(isEnabled: isEnabled && !selected, onChange: { hovered = $0 }).allowsHitTesting(false))
            .animation(reduceMotion ? nil : ChromeMotion.press, value: hovered)
    }
}

private struct ChromeHoverTracker: NSViewRepresentable {
    let isEnabled: Bool
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ChromeHoverView { ChromeHoverView() }
    func updateNSView(_ view: ChromeHoverView, context: Context) {
        view.onChange = onChange
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
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private var mouseMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var hovered: Bool?
    override func layout() {
        super.layout()
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
        guard hovered != value else { return }
        hovered = value
        // Pointer validation also runs during SwiftUI layout updates.
        let callback = onChange
        DispatchQueue.main.async { callback?(value) }
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
