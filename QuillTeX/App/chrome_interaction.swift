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
            .scaleEffect(pressed && !reduceMotion ? ChromeMotion.pressedScale : 1)
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
    /// When present, the same AppKit hover event that reveals the underline
    /// shows this custom tooltip immediately. The system `.help` delay is not
    /// involved.
    var tooltip: String? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var hoverAnchor: NSView?
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.primaryInk.opacity(0.7))
                    .frame(width: 10, height: 1.5).padding(.bottom, 2)
                    .opacity(hovered && !selected ? 1 : 0).allowsHitTesting(false)
            }
            .scaleEffect(hovered && !reduceMotion ? 1.055 : 1)
            .offset(y: hovered && !reduceMotion ? -0.75 : 0)
            .background(ChromeHoverTracker(
                isEnabled: isEnabled && !selected,
                onChange: { hovered = $0 },
                onHoverView: { isHovering, anchor in
                    hoverAnchor = isHovering ? anchor : nil
                    guard let tooltip else { return }
                    if isHovering {
                        HoverTipPresenter.shared.show(tooltip, anchor: anchor)
                    } else {
                        HoverTipPresenter.shared.hide()
                    }
                }
            ).allowsHitTesting(false))
            .onChange(of: tooltip) { _, next in
                guard hovered, let anchor = hoverAnchor, let next else { return }
                HoverTipPresenter.shared.show(next, anchor: anchor)
            }
            .onDisappear {
                HoverTipPresenter.shared.hide()
            }
            .animation(reduceMotion ? nil : ChromeMotion.press, value: hovered)
    }
}

/// Reports pointer hover through the same AppKit tracking layer as the top bar,
/// without adding its own visual effect. SwiftUI's `onHover` and `Menu` labels
/// do not receive reliable hover events in this hosting setup.
struct ChromeHoverState: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> ChromeHoverView { ChromeHoverView() }
    func updateNSView(_ view: ChromeHoverView, context: Context) {
        view.onChange = onChange
        view.isControlEnabled = true
        view.refreshHover()
    }
    static func dismantleNSView(_ view: ChromeHoverView, coordinator: ()) {
        view.isControlEnabled = false
        view.onChange = nil
    }
}

private struct ChromeHoverTracker: NSViewRepresentable {
    let isEnabled: Bool
    let onChange: (Bool) -> Void
    var onHoverView: ((Bool, NSView) -> Void)? = nil
    func makeNSView(context: Context) -> ChromeHoverView { ChromeHoverView() }
    func updateNSView(_ view: ChromeHoverView, context: Context) {
        view.onChange = onChange
        view.onHoverView = onHoverView
        view.isControlEnabled = isEnabled
        view.refreshHover()
    }
    static func dismantleNSView(_ view: ChromeHoverView, coordinator: ()) {
        view.isControlEnabled = false
        view.onHoverView = nil
        view.refreshHover()
    }
}

final class ChromeHoverView: NSView {
    var isControlEnabled = true
    var onChange: ((Bool) -> Void)?
    var onHoverView: ((Bool, NSView) -> Void)?
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
        let anchorCallback = onHoverView
        DispatchQueue.main.async { [weak self] in
            callback?(value)
            if let self { anchorCallback?(value, self) }
        }
    }
}

/// A small, non-activating tooltip panel driven by `ChromeHoverFeedback`.
/// It is deliberately separate from AppKit's `.help` mechanism so the tooltip
/// appears on the same hover event as the underline, not after a system delay.
@MainActor
final class HoverTipPresenter {
    static let shared = HoverTipPresenter()

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?

    func show(_ text: String, anchor: NSView) {
        guard let window = anchor.window else { return }
        let panel = existingPanel()
        guard let titleLabel, let detailLabel else { return }

        let parts = text.components(separatedBy: "\n")
        let title = parts.first ?? ""
        let detail = parts.dropFirst().joined(separator: " ")
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty

        let titleFont = titleLabel.font ?? NSFont.systemFont(ofSize: 11, weight: .medium)
        let detailFont = detailLabel.font ?? NSFont.systemFont(ofSize: 10.5)
        let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
        let detailWidth = detail.isEmpty ? 0 : (detail as NSString).size(withAttributes: [.font: detailFont]).width
        let textWidth = min(260, max(80, ceil(max(titleWidth, detailWidth))))
        let titleHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        let detailHeight = ceil(detailFont.ascender - detailFont.descender + detailFont.leading)
        let padding: CGFloat = 9
        let spacing: CGFloat = 2
        let height = padding * 2 + titleHeight + (detail.isEmpty ? 0 : spacing + detailHeight)
        let width = textWidth + padding * 2

        panel.setContentSize(NSSize(width: width, height: height))
        titleLabel.frame = NSRect(x: padding, y: height - padding - titleHeight,
                                  width: textWidth, height: titleHeight)
        detailLabel.frame = NSRect(x: padding, y: padding, width: textWidth, height: detailHeight)

        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = window.convertToScreen(anchorInWindow)
        let screen = window.screen ?? NSScreen.main
        var origin = NSPoint(x: anchorOnScreen.maxX - width,
                             y: anchorOnScreen.minY - height - 5)
        if let screen {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = anchorOnScreen.maxY + 5
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - height - 4)
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.appearance = NSAppearance(named: .aqua)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        container.layer?.borderWidth = 0.7
        container.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        panel.contentView = container

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.cell?.usesSingleLineMode = true
        title.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(title)

        let detail = NSTextField(labelWithString: "")
        detail.font = NSFont.systemFont(ofSize: 10.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.cell?.usesSingleLineMode = true
        detail.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(detail)

        titleLabel = title
        detailLabel = detail
        self.panel = panel
        return panel
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
    // The custom top bar replaces the real titlebar, so AppKit's titlebar
    // double-click handling never sees these clicks. Handle the drag and the
    // system double-click action explicitly instead.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performTitlebarDoubleClick(on: window)
        } else {
            // performWindowDrag(with:) is public AppKit API but is not exposed to
            // Swift by the SDK's generated interface; the Objective-C selector is
            // stable and lets the Window Server own the drag (spaces, snapping).
            let selector = NSSelectorFromString("performWindowDragWithEvent:")
            if window.responds(to: selector) { _ = window.perform(selector, with: event) }
        }
    }

    private static func performTitlebarDoubleClick(on window: NSWindow) {
        // Same preference the native titlebar reads: Maximize = zoom to the
        // window's standard frame, Minimize = dock, None = do nothing.
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// Hosts a chrome row flush with the window's content top. The window keeps its
/// titlebar area as a safe-area inset, which otherwise pushes the sidebar and the
/// content top bar down by the titlebar height.
@MainActor
func chromeHostingController<Content: View>(_ rootView: Content) -> NSHostingController<Content> {
    let controller = NSHostingController(rootView: rootView)
    (controller.view as? NSHostingView<Content>)?.safeAreaRegions = []
    return controller
}
