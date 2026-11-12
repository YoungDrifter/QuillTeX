import SwiftUI
import AppKit

/// Shared feedback for list rows and compact controls outside the titlebar.
struct QuillRowButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = ChromeMetrics.popupRowCornerRadius
    func makeBody(configuration: Configuration) -> some View {
        QuillRowFeedback(label: configuration.label, pressed: configuration.isPressed,
                         selected: selected, cornerRadius: cornerRadius)
    }
}

private struct QuillRowFeedback<Label: View>: View {
    let label: Label
    let pressed: Bool
    let selected: Bool
    let cornerRadius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        label
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Palette.primaryInk.opacity(isEnabled && pressed ? Palette.pressedOpacity :
                    (selected ? Palette.selectedOpacity : (isEnabled && hovered ? Palette.chromeHoverOpacity : 0)))))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .scaleEffect(isEnabled && pressed && !reduceMotion ? ChromeMotion.pressedScale : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : ChromeMotion.feedback, value: hovered)
            .animation(reduceMotion ? nil : ChromeMotion.feedback, value: selected)
            .animation(reduceMotion ? nil : ChromeMotion.press, value: pressed)
    }
}

/// Shared, shadow-free surface for every app-owned floating panel, matching
/// PaperLens 1.0.3: light material, hairline edge, no custom drop shadow.
struct QuillPanelSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.panelCornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency { shape.fill(Palette.controlSurface) }
                else { shape.fill(.regularMaterial).overlay(shape.fill(Color.white.opacity(0.65))) }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 0.7).allowsHitTesting(false))
            .foregroundStyle(Palette.primaryInk)
            .preferredColorScheme(.light)
    }
}

/// Content of a native popover: the panel supplies its own chrome, so this only
/// fixes padding, ink and the light appearance.
struct QuillPopoverContent: ViewModifier {
    var padding: CGFloat = ChromeMetrics.panelPadding
    func body(content: Content) -> some View {
        content.padding(padding)
            .font(.system(size: 13))
            .foregroundStyle(Palette.primaryInk)
            .tint(.black)
            .background(Color.white)
            .preferredColorScheme(.light)
    }
}

struct QuillSheetContent: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(ChromeMetrics.panelPadding)
            .foregroundStyle(Palette.primaryInk)
            .tint(.black)
            .background(Color.white)
            .preferredColorScheme(.light)
    }
}

struct QuillPopoverTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct QuillPopoverSettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: ChromeMetrics.popoverLabelWidth, height: ChromeMetrics.popoverControlHeight, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
    }
}

extension View {
    func quillPanelSurface() -> some View { modifier(QuillPanelSurface()) }
    func quillPopoverContent(padding: CGFloat = ChromeMetrics.panelPadding) -> some View { modifier(QuillPopoverContent(padding: padding)) }
    func quillSheetContent() -> some View { modifier(QuillSheetContent()) }

    /// One row inside an app-owned popup list: the same quiet wash everywhere, so
    /// recent projects, project files and the other popups read alike.
    func quillPopupRow(active: Bool) -> some View {
        modifier(QuillPopupRowFeedback(active: active))
    }
}

private struct QuillPopupRowFeedback: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: ChromeMetrics.popupRowCornerRadius, style: .continuous)
                .fill(Palette.primaryInk.opacity(active ? Palette.selectedOpacity : 0))
                .animation(reduceMotion ? nil : ChromeMotion.feedback, value: active)
        }
    }
}

/// Icon, title and secondary path — the shared content of a popup list row.
struct QuillPopupRowLabel: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Hover-revealed delete control for a popup row. The slot is always part of the
/// layout, so revealing the control never reflows the row.
struct QuillPopupDeleteButton: View {
    let title: String
    var visible: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.secondaryInk)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(ChromeButtonStyle()).modifier(ChromeHoverFeedback())
        .help("Remove from Recents")
        .accessibilityLabel("Remove \(title) from Recents")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }
}

/// The sidebar uses the same arrow column, weight and rotation in every mode.
struct QuillSidebarDisclosure: View {
    let expanded: Bool
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .medium))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .frame(width: ChromeMetrics.sidebarDisclosureWidth, height: ChromeMetrics.sidebarRowHeight)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

/// Reveal a branch at its natural width while smoothly changing its occupied height.
/// Children keep their layout during the transition, rather than stretching or bouncing.
struct QuillBranchReveal: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        QuillBranchLayout(progress: progress) { content }
            .clipped()
            .opacity(progress)
    }
}

private struct QuillBranchLayout: Layout {
    var progress: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: size.width, height: size.height * progress)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
    }

}

/// Blurred behind-window material for the workspace sidebar and launcher left
/// column. The veil keeps the background as a soft tint; the material's own blur
/// prevents the desktop text from becoming readable.
struct SidebarBackdrop: View {
    var opaque = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if opaque || reduceTransparency {
            Palette.sidebarSurface
        } else {
            ZStack {
                VisualEffectBackdrop()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Palette.sidebarVeil
            }
            .allowsHitTesting(false)
        }
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

// MARK: - App-owned dialogs

/// Button roles shared by every app-created dialog: one full-width primary
/// action and a row of quiet secondary actions.
struct QuillDialogAction: Identifiable {
    enum Kind { case primary, secondary, destructive }
    let id = UUID()
    var title: String
    var kind: Kind = .secondary
    var code: Int
    var isCancel = false

    static func primary(_ title: String, code: Int = 1) -> QuillDialogAction {
        QuillDialogAction(title: title, kind: .primary, code: code)
    }
    static func secondary(_ title: String, code: Int, isCancel: Bool = false) -> QuillDialogAction {
        QuillDialogAction(title: title, code: code, isCancel: isCancel)
    }
    static func destructive(_ title: String, code: Int) -> QuillDialogAction {
        QuillDialogAction(title: title, kind: .destructive, code: code)
    }
}

struct QuillDialogButtonStyle: ButtonStyle {
    var role: QuillDialogAction.Kind = .primary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(background(pressed: pressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(role == .primary ? Color.clear : Palette.hairline, lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(DialogButtonHover())
            .scaleEffect(pressed && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : ChromeMotion.press, value: pressed)
            .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch role {
        case .primary: Palette.primaryInk
        case .secondary: Palette.primaryInk
        case .destructive: .red
        }
    }

    private func background(pressed: Bool) -> Color {
        switch role {
        case .primary:
            return Palette.primaryInk.opacity(pressed ? 0.12 : 0.07)
        case .secondary:
            return Palette.primaryInk.opacity(pressed ? 0.08 : 0.035)
        case .destructive:
            return Color.red.opacity(pressed ? 0.16 : 0.08)
        }
    }
}

/// The one hover treatment for capsule controls: a quiet gray inner wash,
/// never scale, underline or shadow changes.
struct CapsuleHoverWash: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .overlay {
                Capsule()
                    .fill(Color.black.opacity(hovered ? 0.05 : 0))
                    .padding(3)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// Quiet hover lift for dialog actions (Save/Create/Update and confirm buttons).
struct DialogButtonHover: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(hovered ? 0.045 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct QuillDialogTextButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(destructive ? Color.red : Palette.secondaryInk)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.primaryInk.opacity(configuration.isPressed ? 0.07 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : ChromeMotion.feedback, value: configuration.isPressed)
    }
}

/// The floating card used by every app-owned dialog. Its layout follows the
/// reference: title row with a close button, hairline separators, labelled
/// fields and one full-width primary action.
struct QuillDialogCard<Content: View>: View {
    let title: String
    var width: CGFloat = 380
    var cancelCode = 0
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    let actions: [QuillDialogAction]
    let onAction: (Int) -> Void
    var primaryEnabled = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var closeHovered = false

    private var primary: QuillDialogAction? {
        actions.first { $0.kind == .primary }
    }
    private var secondary: [QuillDialogAction] {
        actions.filter { $0.kind != .primary }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline.opacity(0.7)).frame(height: 0.8)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .frame(width: width)
        .background {
            // Same translucent glass language as the toolbar capsules: a blurred
            // material with a light white veil instead of an opaque white card, so
            // dialogs sit in the window rather than on top of it.
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.22))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.9)
        }
        .shadow(color: .black.opacity(0.16), radius: 34, y: 14)
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.97, anchor: .center)
        .offset(y: appeared ? 0 : 6)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.primaryInk)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.secondaryInk)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Palette.primaryInk.opacity(closeHovered ? 0.09 : 0.05)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let primary {
                Button(primary.title) { onAction(primary.code) }
                    .buttonStyle(QuillDialogButtonStyle(role: primary.kind))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!primaryEnabled)
            }
            if !secondary.isEmpty {
                HStack(spacing: 4) {
                    ForEach(secondary) { action in
                        Button(action.title) { onAction(action.code) }
                            .buttonStyle(QuillDialogTextButtonStyle(destructive: action.kind == .destructive))
                            .modifier(CancelShortcut(isCancel: action.isCancel))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }
}

private struct CancelShortcut: ViewModifier {
    let isCancel: Bool
    func body(content: Content) -> some View {
        if isCancel { content.keyboardShortcut(.cancelAction) } else { content }
    }
}

struct QuillDialogMessage: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label above a filled field, matching the reference dialog.
struct QuillDialogFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.secondaryInk)
    }
}

struct QuillDialogField<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.primaryInk.opacity(0.05))
            }
    }
}

/// A labelled row with hairline separator above it, like the reference's
/// Description / Icon / Color rows.
struct QuillDialogRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.primaryInk)
            Spacer(minLength: 12)
            content()
        }
        .frame(minHeight: 42)
        .overlay(alignment: .top) {
        }
    }
}

/// The window content stays fully visible behind a dialog; the backdrop is
/// only an invisible hit target that keeps the card floating above the page.
struct QuillDialogBackdrop: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
    }
}

/// Presents a card synchronously over the key window, reproducing the same
/// dimmed backdrop and card animation used by in-window overlays.
@MainActor
final class QuillDialogSession {
    fileprivate var code: Int?
    fileprivate weak var panel: NSWindow?
    fileprivate var isFinishing = false

    func finish(_ code: Int) {
        guard !isFinishing else { return }
        isFinishing = true
        self.code = code
        guard let panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSApp.stopModal(withCode: NSApplication.ModalResponse(code))
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { NSApp.stopModal(withCode: NSApplication.ModalResponse(code)) })
        }
    }
}

private final class QuillDialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onConfirm?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
enum QuillDialog {
    static func alert(title: String, message: String? = nil) {
        _ = present(title: title, width: 400,
                    actions: [.primary("OK")]) {
            if let message, !message.isEmpty { QuillDialogMessage(message) }
        }
    }

    @discardableResult
    static func confirm(title: String, message: String? = nil, confirmTitle: String,
                        destructive: Bool = false) -> Bool {
        let action: QuillDialogAction = destructive ? .destructive(confirmTitle, code: 1) : .primary(confirmTitle)
        return present(title: title, width: 400, actions: [action]) {
            if let message, !message.isEmpty { QuillDialogMessage(message) }
        } == 1
    }

    static func prompt(title: String, message: String? = nil, initial: String, placeholder: String,
                       confirmTitle: String) -> String? {
        let state = QuillPromptState(initial)
        let code = present(title: title, width: 420, actions: [.primary(confirmTitle)]) {
            VStack(alignment: .leading, spacing: 14) {
                if let message, !message.isEmpty { QuillDialogMessage(message) }
                QuillDialogPromptField(state: state, placeholder: placeholder)
            }
        }
        return code == 1 ? state.text : nil
    }

    @discardableResult
    static func present<Content: View>(title: String, width: CGFloat = 460, cancelCode: Int = 0,
                                       primaryEnabled: Bool = true,
                                       actions: [QuillDialogAction],
                                       @ViewBuilder content: @escaping () -> Content) -> Int {
        let session = QuillDialogSession()
        let parentWidth = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame.width ?? 1280
        let resolvedWidth = min(width, max(340, parentWidth * 0.66))
        let card = QuillDialogCard(title: title, width: resolvedWidth, cancelCode: cancelCode,
                                   close: { session.finish(cancelCode) },
                                   content: content,
                                   actions: actions,
                                   onAction: { session.finish($0) },
                                   primaryEnabled: primaryEnabled)
        let root = ZStack {
            QuillDialogBackdrop()
            card.padding(36)
        }
        let panel = QuillDialogPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: root)
        panel.onCancel = { session.finish(cancelCode) }
        panel.onConfirm = {
            guard primaryEnabled, let primary = actions.first(where: { $0.kind == .primary }) else { return }
            session.finish(primary.code)
        }
        session.panel = panel
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.setFrame(parent.frame, display: false)
        } else {
            panel.center()
        }
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
            }
        }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return session.code ?? cancelCode
    }
}

@MainActor
final class QuillPromptState: ObservableObject {
    @Published var text: String
    init(_ text: String) { self.text = text }
}

private struct QuillDialogPromptField: View {
    @ObservedObject var state: QuillPromptState
    let placeholder: String
    var body: some View {
        QuillDialogField {
            TextField(placeholder, text: $state.text)
                .textFieldStyle(.plain)
        }
    }
}

// MARK: - Async overlay dialogs

struct QuillAlertRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
}

struct QuillConfirmRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var confirmTitle: String
    var destructive = false
    var secondaryTitle: String?
    var completion: (Bool) -> Void
    var secondaryCompletion: (() -> Void)?
}

struct QuillPromptRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    var initial: String
    var placeholder: String
    var confirmTitle: String
    var completion: (String?) -> Void
}

enum QuillCloseChoice { case save, discard, cancel }

struct QuillSaveChangesRequest: Identifiable {
    let id = UUID()
    var title: String
    var detail: String?
    var completion: (QuillCloseChoice) -> Void
}

/// Non-blocking dialogs presented inside the workspace. They replace nested
/// modal run loops, which cannot reliably render SwiftUI content when started
/// from a button action.
@MainActor
final class QuillDialogCenter: ObservableObject {
    static let shared = QuillDialogCenter()

    @Published var alert: QuillAlertRequest?
    @Published var confirmRequest: QuillConfirmRequest?
    @Published var promptRequest: QuillPromptRequest?
    @Published var saveChanges: QuillSaveChangesRequest?

    func showAlert(_ title: String, _ message: String? = nil) {
        alert = QuillAlertRequest(title: title, message: message)
    }

    func showConfirm(title: String, message: String? = nil, confirmTitle: String,
                     destructive: Bool = false, secondaryTitle: String? = nil,
                     completion: @escaping (Bool) -> Void,
                     secondaryCompletion: (() -> Void)? = nil) {
        confirmRequest = QuillConfirmRequest(title: title, message: message, confirmTitle: confirmTitle,
                                             destructive: destructive, secondaryTitle: secondaryTitle,
                                             completion: completion, secondaryCompletion: secondaryCompletion)
    }

    func showPrompt(title: String, message: String? = nil, initial: String,
                    placeholder: String, confirmTitle: String,
                    completion: @escaping (String?) -> Void) {
        promptRequest = QuillPromptRequest(title: title, message: message, initial: initial,
                                           placeholder: placeholder, confirmTitle: confirmTitle,
                                           completion: completion)
    }

    func showSaveChanges(title: String, detail: String?, completion: @escaping (QuillCloseChoice) -> Void) {
        saveChanges = QuillSaveChangesRequest(title: title, detail: detail, completion: completion)
    }
}

struct QuillOverlayAlert: View {
    let request: QuillAlertRequest
    let dismiss: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuillDialogBackdrop()
                QuillDialogCard(title: request.title,
                                width: min(370, max(320, geometry.size.width * 0.56)),
                                close: dismiss,
                                content: {
                                    if let message = request.message, !message.isEmpty {
                                        QuillDialogMessage(message)
                                    }
                                },
                                actions: [.primary("OK")],
                                onAction: { _ in dismiss() })
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct QuillOverlayConfirm: View {
    let request: QuillConfirmRequest
    let dismiss: () -> Void
    @State private var secondaryHovered = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuillDialogBackdrop()
                QuillDialogCard(title: request.title,
                                width: min(370, max(320, geometry.size.width * 0.56)),
                                close: { finish(false) },
                                content: {
                                    if let message = request.message, !message.isEmpty {
                                        QuillDialogMessage(message)
                                    }
                                },
                                actions: confirmActions,
                                onAction: { code in
                                    if code == 2 {
                                        request.secondaryCompletion?()
                                        dismiss()
                                    } else {
                                        finish(true)
                                    }
                                })
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var confirmActions: [QuillDialogAction] {
        var actions: [QuillDialogAction] = []
        if let secondary = request.secondaryTitle {
            actions.append(.secondary(secondary, code: 2))
        }
        actions.append(request.destructive ? .destructive(request.confirmTitle, code: 1)
                                           : .primary(request.confirmTitle))
        return actions
    }

    private func finish(_ confirmed: Bool) {
        request.completion(confirmed)
        dismiss()
    }
}

struct QuillOverlayPrompt: View {
    let request: QuillPromptRequest
    let dismiss: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(request: QuillPromptRequest, dismiss: @escaping () -> Void) {
        self.request = request
        self.dismiss = dismiss
        _text = State(initialValue: request.initial)
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuillDialogBackdrop()
                QuillDialogCard(title: request.title,
                                width: min(380, max(330, geometry.size.width * 0.56)),
                                close: { finish(nil) },
                                content: { form },
                                actions: [.primary(request.confirmTitle)],
                                onAction: { _ in finish(trimmed) },
                                primaryEnabled: !trimmed.isEmpty)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { focused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = request.message, !message.isEmpty {
                QuillDialogMessage(message)
            }
            QuillDialogField {
                TextField(request.placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if !trimmed.isEmpty { finish(trimmed) } }
            }
        }
    }

    private func finish(_ value: String?) {
        request.completion(value)
        dismiss()
    }
}

struct QuillOverlaySaveChanges: View {
    let request: QuillSaveChangesRequest
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                QuillDialogBackdrop()
                QuillDialogCard(title: request.title,
                                width: min(380, max(330, geometry.size.width * 0.56)),
                                close: { finish(.cancel) },
                                content: {
                                    if let detail = request.detail, !detail.isEmpty {
                                        QuillDialogMessage(detail)
                                    }
                                },
                                actions: [.primary("Save"),
                                          .destructive("Discard Changes", code: 2)],
                                onAction: { code in finish(code == 2 ? .discard : .save) })
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func finish(_ choice: QuillCloseChoice) {
        request.completion(choice)
        dismiss()
    }
}
