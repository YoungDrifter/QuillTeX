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
    var onAccept: (() -> Void)?
    private var popupSize = CGSize(width: 240, height: 120)

    var isVisible: Bool { panel.isVisible }
    var selectedItem: LaTeXCompletion.Item? { items.indices.contains(selection) ? items[selection] : nil }

    init() {
        panel = CompletionPopupPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
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
        host = NSHostingView(rootView: CompletionList(items: [], selection: 0, width: 240, height: 120, accept: { _ in }))
        host.wantsLayer = true
        panel.contentView = host
    }

    /// Shows the list under `caret` (screen coordinates), flipping above it when the
    /// window has no room below.
    func show(items: [LaTeXCompletion.Item], selection: Int, under caret: NSRect) {
        guard !items.isEmpty else { hide(); return }
        self.items = items
        self.selection = min(max(0, selection), items.count - 1)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: caret.minX, y: caret.minY - 320, width: 480, height: 640)
        let frame = Self.popupFrame(width: LaTeXCompletion.panelWidth(for: items), count: items.count,
                                   caret: caret, visibleFrame: visible)
        popupSize = frame.size
        updateList()
        panel.setFrame(frame, display: true)
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
        updateList()
    }

    private func updateList() {
        host.rootView = CompletionList(items: items, selection: selection, width: popupSize.width,
                                       height: popupSize.height) { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.selection = index
            self.onAccept?()
        }
    }

    /// Keep the popup within the usable display, including near its top and right edges.
    static func popupFrame(width: CGFloat, count: Int, caret: NSRect, visibleFrame: NSRect) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(width, bounds.width)
        let desiredHeight = min(300, CGFloat(count) * 25 + 11)
        let below = max(0, caret.minY - 6 - bounds.minY)
        let above = max(0, bounds.maxY - caret.maxY - 6)
        let useBelow = below >= desiredHeight || below >= above
        let room = useBelow ? below : above
        let height = min(desiredHeight, max(24, room), bounds.height)
        let x = min(max(caret.minX - 6, bounds.minX), bounds.maxX - width)
        let proposedY = useBelow ? caret.minY - height - 6 : caret.maxY + 6
        let y = min(max(proposedY, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// Keyboard selection and pointer hover stay distinct; clicking accepts the candidate.
private struct CompletionList: View {
    let items: [LaTeXCompletion.Item]
    let selection: Int
    let width: CGFloat
    let height: CGFloat
    let accept: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CompletionRow(item: item, selected: index == selection) { accept(index) }
                            .id(index)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selection) { _ in proxy.scrollTo(selection) }
            .onChange(of: items.map(\.id)) { _ in proxy.scrollTo(selection) }
            .onAppear { proxy.scrollTo(selection) }
        }
        .frame(width: width, height: height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.10)))
        .preferredColorScheme(.light)
    }
}

private struct CompletionRow: View {
    let item: LaTeXCompletion.Item
    let selected: Bool
    let accept: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: accept) {
            HStack {
                Text(item.title).font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(selected ? 0.10 : (hovered ? 0.06 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hovered = $0 }
        .help(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private final class CompletionPopupPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
