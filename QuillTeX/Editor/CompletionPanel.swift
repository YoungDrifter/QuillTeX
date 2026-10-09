import AppKit
import SwiftUI

/// The completion popup: a borderless panel drawn by us, so the candidate list looks
/// like the rest of the app instead of the system's plain menu.
@MainActor
final class CompletionPanel {
    private let panel: NSPanel
    private let host: NSHostingView<CompletionList>
    private var items: [LaTeXCompletion.Item] = []
    private(set) var selection = 0

    var isVisible: Bool { panel.isVisible }
    var selectedItem: LaTeXCompletion.Item? { items.indices.contains(selection) ? items[selection] : nil }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        host = NSHostingView(rootView: CompletionList(items: [], selection: 0, width: 240))
        host.wantsLayer = true
        panel.contentView = host
    }

    /// Shows the list under `caret` (screen coordinates), flipping above it when the
    /// window has no room below.
    func show(items: [LaTeXCompletion.Item], selection: Int, under caret: NSRect) {
        guard !items.isEmpty else { hide(); return }
        self.items = items
        self.selection = min(max(0, selection), items.count - 1)
        host.rootView = CompletionList(items: items, selection: self.selection,
                                       width: LaTeXCompletion.panelWidth(for: items))
        let size = host.fittingSize
        var origin = NSPoint(x: caret.minX - 6, y: caret.minY - size.height - 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }), origin.y < screen.visibleFrame.minY {
            origin.y = caret.maxY + 6
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        items = []
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
        host.rootView = CompletionList(items: items, selection: selection,
                                       width: LaTeXCompletion.panelWidth(for: items))
    }
}

/// The rows themselves: monospaced candidate plus a one-line explanation, in the same
/// monochrome, rounded language as the rest of the window.
private struct CompletionList: View {
    let items: [LaTeXCompletion.Item]
    let selection: Int
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(index == selection ? 0.10 : 0)))
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.10)))
        .preferredColorScheme(.light)
    }
}
