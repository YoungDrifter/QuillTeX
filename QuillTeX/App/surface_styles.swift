import SwiftUI

/// Shared feedback for list rows and compact controls outside the titlebar.
struct QuillRowButtonStyle: ButtonStyle {
    var selected = false
    var cornerRadius: CGFloat = 8
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
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .scaleEffect(isEnabled && pressed && !reduceMotion ? 0.985 : 1)
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
        background(RoundedRectangle(cornerRadius: 8).fill(Palette.primaryInk.opacity(active ? Palette.selectedOpacity : 0)))
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
