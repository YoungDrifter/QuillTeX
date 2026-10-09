import AppKit
import SwiftUI

/// The same settings layout is used by QuillTeX and PaperLens.
enum SettingsStyle {
    static let windowSize = CGSize(width: 780, height: 600)
    static let minimumSize = CGSize(width: 720, height: 560)
    static let sidebarWidth: CGFloat = 184
    static let padding: CGFloat = 28
    static let rowHeight: CGFloat = 40
    static let surface = Color.white
    static let secondarySurface = Color.black.opacity(0.018)
    static let selection = Color.black.opacity(0.065)
    static let border = Color.black.opacity(0.09)
}

struct SettingsCategory<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let symbol: String
}

struct SettingsLayout<ID: Hashable, Content: View>: View {
    let appName: String
    let version: String
    let icon: NSImage
    let categories: [SettingsCategory<ID>]
    @Binding var selection: ID
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(nsImage: icon).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appName).font(.system(size: 15, weight: .semibold))
                        Text("Settings").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                VStack(spacing: 4) {
                    ForEach(categories) { category in
                        SettingsCategoryButton(title: category.title, symbol: category.symbol,
                                               selected: selection == category.id) {
                            selection = category.id
                        }
                    }
                }
                Spacer(minLength: 0)
                Text("Version \(version)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            .padding(.horizontal, 12).padding(.vertical, 24)
            .frame(width: SettingsStyle.sidebarWidth)
            .background(SettingsStyle.secondarySurface)
            Rectangle().fill(SettingsStyle.border).frame(width: 1)
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SettingsStyle.surface)
        .foregroundStyle(Color.black)
        .tint(.black)
        .frame(minWidth: SettingsStyle.minimumSize.width, idealWidth: SettingsStyle.windowSize.width,
               minHeight: SettingsStyle.minimumSize.height, idealHeight: SettingsStyle.windowSize.height)
        .preferredColorScheme(.light)
        .background(SettingsWindowConfiguration(appName: appName))
    }
}

private struct SettingsCategoryButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(selected ? SettingsStyle.selection : (hovering ? SettingsStyle.secondarySurface : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 24, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsStyle.padding)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SettingsStyle.border, lineWidth: 1))
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: SettingsStyle.rowHeight).padding(.vertical, 4)
    }
}

struct SettingsActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).frame(minHeight: 28)
            .background(Color.black.opacity(configuration.isPressed ? 0.08 : 0.025), in: Capsule())
            .overlay(Capsule().strokeBorder(SettingsStyle.border, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct SettingsIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

/// Keep the native titlebar; a plain HStack avoids PaperLens's NSSplitView responder fault.
private struct SettingsWindowConfiguration: NSViewRepresentable {
    let appName: String
    func makeNSView(context: Context) -> WindowView { WindowView(appName: appName) }
    func updateNSView(_ view: WindowView, context: Context) { view.configure() }

    final class WindowView: NSView {
        let appName: String
        init(appName: String) { self.appName = appName; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() {
            guard let window else { return }
            window.title = "\(appName) Settings"
            window.appearance = NSAppearance(named: .aqua)
            window.contentMinSize = SettingsStyle.minimumSize
            if let button = window.standardWindowButton(.closeButton) {
                button.keyEquivalent = "\u{1b}"
                button.keyEquivalentModifierMask = []
            }
        }
    }
}
