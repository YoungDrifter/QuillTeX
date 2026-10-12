import SwiftUI

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
    func body(content: Content) -> some View {
        content.padding(ChromeMetrics.panelPadding)
            .foregroundStyle(Palette.primaryInk)
            .background(Palette.controlSurface)
            .preferredColorScheme(.light)
    }
}

struct QuillSheetContent: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(ChromeMetrics.panelPadding)
            .foregroundStyle(Palette.primaryInk)
            .background(Palette.controlSurface)
            .preferredColorScheme(.light)
    }
}

extension View {
    func quillPanelSurface() -> some View { modifier(QuillPanelSurface()) }
    func quillPopoverContent() -> some View { modifier(QuillPopoverContent()) }
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
        .buttonStyle(.plain)
        .help("Remove from Recents")
        .accessibilityLabel("Remove \(title) from Recents")
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}
