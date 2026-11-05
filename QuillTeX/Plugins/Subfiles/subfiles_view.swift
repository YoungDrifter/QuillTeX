import SwiftUI
import AppKit

private struct SubfileDropBounds: PreferenceKey {
    static let defaultValue: [ProjectStore.SubfilePlacement: CGRect] = [:]
    static func reduce(value: inout [ProjectStore.SubfilePlacement: CGRect], nextValue: () -> [ProjectStore.SubfilePlacement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SubfilesList: View {
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject var store: ProjectStore
    @State private var dragged: URL?
    @GestureState private var dragIsActive = false
    @State private var movingID: String?
    @State private var target: ProjectStore.SubfilePlacement?
    @State private var bounds: [ProjectStore.SubfilePlacement: CGRect] = [:]
    @State private var editorOffset: Int?
    @State private var coordinateView: NSView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var includedExpanded = true
    @State private var unlinkedExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                groupTitle("In Main File", expanded: $includedExpanded)
                if includedExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.mainSubfiles.isEmpty {
                            Text("No included subfiles").font(.system(size: 12)).foregroundStyle(.tertiary).padding(10)
                            dropSlot(.end, title: "Insert before document end")
                        }
                        ForEach(store.mainSubfiles) { reference in
                            dropSlot(.before(reference.id), title: "Before " + reference.url.lastPathComponent)
                            row(reference.url, referenceID: reference.id)
                            dropSlot(.after(reference.id), title: "After " + reference.url.lastPathComponent)
                        }
                    }.transition(branchTransition)
                }
                if plugins.option("unlinked", for: PluginManager.subfilesID) {
                Color.clear.frame(height: 16)
                groupTitle("Not in Main File", expanded: $unlinkedExpanded)
                if unlinkedExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.unlinkedSubfiles, id: \.self) { url in row(url, referenceID: nil) }
                        if store.unlinkedSubfiles.isEmpty {
                            Text("No other TeX files").font(.system(size: 12)).foregroundStyle(.tertiary).padding(10)
                        }
                    }.transition(branchTransition)
                }
            }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
            .background(SubfileCoordinateView { coordinateView = $0 })
            .coordinateSpace(name: "subfileDropList")
            .onPreferenceChange(SubfileDropBounds.self) { bounds = $0 }
        }
        .onChange(of: dragIsActive) { _, active in if !active { clearDrag() } }
        .onDisappear { clearDrag() }
        .onChange(of: store.sidebarMode) { _, mode in if mode != .subfiles { clearDrag() } }
    }

    private var branchTransition: AnyTransition {
        reduceMotion ? .identity : .modifier(active: QuillBranchReveal(progress: 0), identity: QuillBranchReveal(progress: 1))
    }

    private func groupTitle(_ title: String, expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 7) {
                QuillSidebarDisclosure(expanded: expanded.wrappedValue)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }.foregroundStyle(Palette.primaryInk).padding(.leading, 3).padding(.trailing, 6)
                .frame(height: ChromeMetrics.sidebarRowHeight).contentShape(Rectangle())
        }.buttonStyle(QuillRowButtonStyle()).accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    private func row(_ url: URL, referenceID: String?) -> some View {
        Button {
            if dragged == nil { store.openSource(url) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").font(.system(size: 12)).frame(width: ChromeMetrics.sidebarIconWidth)
                Text(plugins.option("extensions", for: PluginManager.subfilesID) ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
            }.padding(.leading, 3).padding(.trailing, 6).frame(minHeight: ChromeMetrics.sidebarRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuillRowButtonStyle(selected: store.activeDocument?.url == url))
        .opacity(dragged == url && movingID == referenceID ? 0.45 : 1)
        .help(store.relativePath(url))
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("subfileDropList"))
            .updating($dragIsActive) { _, active, _ in active = true }
            .onChanged { value in
                dragged = url; movingID = referenceID
                editorOffset = screenPoint(value.location).flatMap { store.previewSubfileInsertion(atScreenPoint: $0) }
                if editorOffset != nil { target = nil }
                else { target = bounds.first { $0.value.contains(value.location) }?.key }
            }
            .onEnded { value in
                editorOffset = screenPoint(value.location).flatMap { store.previewSubfileInsertion(atScreenPoint: $0) }
                if editorOffset == nil { target = bounds.first { $0.value.contains(value.location) }?.key }
                defer { clearDrag() }
                guard let dragged else { return }
                let placement = editorOffset.map { ProjectStore.SubfilePlacement.editorOffset($0) } ?? target
                guard let placement else { return }
                do { try store.insertSubfile(dragged, moving: movingID, at: placement) }
                catch { store.showError("Could Not Insert Subfile", error.localizedDescription) }
            })
        .accessibilityAction(named: Text("Insert at End of Main File")) {
            do { try store.insertSubfile(url, moving: referenceID, at: .end) }
            catch { store.showError("Could Not Insert Subfile", error.localizedDescription) }
        }
    }

    private func dropSlot(_ placement: ProjectStore.SubfilePlacement, title: String) -> some View {
        let before: Bool = { if case .before = placement { return true }; return false }()
        let gap: CGFloat = dragged == nil ? 0 : 4
        return Color.clear.frame(height: gap)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Palette.primaryInk.opacity(target == placement ? 0.65 : 0.16))
                    .frame(maxWidth: target == placement ? .infinity : 28).frame(height: 1)
                    .offset(y: gap > 0 ? gap / 2 : (before ? 2 : -2))
                    .opacity(dragged == nil ? 0 : 1).allowsHitTesting(false)
            }
            .background(GeometryReader { geometry in
                let frame = geometry.frame(in: .named("subfileDropList"))
                let zone = gap > 0 ? frame : CGRect(
                    x: frame.minX, y: frame.minY + (before ? 0 : -8), width: frame.width, height: 8)
                Color.clear.preference(key: SubfileDropBounds.self, value: [placement: zone])
            })
            .accessibilityHidden(dragged == nil)
            .accessibilityLabel(title).help(title)
    }

    private func screenPoint(_ point: CGPoint) -> NSPoint? {
        guard let coordinateView, let window = coordinateView.window else { return nil }
        return window.convertPoint(toScreen: coordinateView.convert(point, to: nil))
    }

    private func clearDrag() {
        dragged = nil; movingID = nil; target = nil; editorOffset = nil
        store.clearSubfileInsertionPreview()
    }
}

/// Convert the gesture's list coordinates through the actual hosting window.
/// NSEvent.mouseLocation can still describe a different event during local drags.
private struct SubfileCoordinateView: NSViewRepresentable {
    let onResolve: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

