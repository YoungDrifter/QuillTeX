import AppKit
import SwiftUI

/// Keep the editor as first responder while sharing the application's popup surface and rows.
@MainActor
final class CompletionPopup {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let model = CompletionListModel()
    private(set) var values: [String] = []
    var frame: NSRect { panel.frame }
    var accept: ((String) -> Void)?
    var isVisible: Bool { panel.isVisible }
    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: CompletionList(model: model) { [weak self] value in self?.accept?(value) })
    }
    func show(_ candidates: [LaTeXCompletion.Candidate], anchor: NSRect, owner: NSWindow) {
        let previous = selected
        values = candidates.map(\.value)
        guard !values.isEmpty else { close(); return }
        let visible = owner.screen?.visibleFrame ?? anchor
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let detailFont = NSFont.systemFont(ofSize: 11)
        let natural = candidates.map { ($0.value as NSString).size(withAttributes: [.font: titleFont]).width + ($0.detail as NSString).size(withAttributes: [.font: detailFont]).width + 64 }.max() ?? 280
        let width = min(max(280, natural), 440, visible.width)
        let height = min(CGFloat(values.count) * 34 + 16, 300, visible.height)
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 4)
        if origin.y < visible.minY { origin.y = anchor.maxY + 4 }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
        model.candidates = candidates
        model.selection = previous.flatMap { values.firstIndex(of: $0) } ?? 0
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if panel.parent !== owner { panel.parent?.removeChildWindow(panel); owner.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    var selected: String? { values.indices.contains(model.selection) ? values[model.selection] : nil }
    func move(_ delta: Int) { model.selection = max(0, min(values.count - 1, model.selection + delta)) }
    func close() { panel.orderOut(nil); panel.parent?.removeChildWindow(panel) }
}

@MainActor
private final class CompletionListModel: ObservableObject {
    @Published var candidates: [LaTeXCompletion.Candidate] = []
    @Published var selection = 0
}

private struct CompletionList: View {
    @ObservedObject var model: CompletionListModel
    let accept: (String) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.candidates.enumerated()), id: \.element.value) { index, item in
                        Button { accept(item.value) } label: {
                            HStack(spacing: 12) {
                                Text(item.value).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10).frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .quillPopupRow(active: model.selection == index)
                        .onHover { if $0 { model.selection = index } }
                        .id(index)
                    }
                }
            }
            .onChange(of: model.selection) { _, value in proxy.scrollTo(value) }
        }
        .padding(8)
        .quillPanelSurface()
        .accessibilityLabel("Completion candidates")
    }
}
