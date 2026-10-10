import SwiftUI

struct ProjectSidebar: View {
    @ObservedObject var store: ProjectStore
    var body: some View {
        VStack(spacing: 0) {
            sidebarModes.padding(.top, 12).padding(.bottom, 12)
            HStack {
                Text(store.sidebarMode.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if store.isIndexing { ProgressView().controlSize(.mini) }
                if store.sidebarMode == .subfiles || store.sidebarMode == .folder {
                    SidebarActionButton(icon: "doc.badge.plus", title: store.sidebarMode == .subfiles ? "New Subfile" : "New TeX File",
                                        help: store.creationDirectory.map { "Create a subfile in " + $0.path } ?? "Open a project first") {
                        store.newSubfile()
                    }.disabled(store.root == nil)
                    if store.sidebarMode == .folder {
                        SidebarActionButton(icon: "folder.badge.plus", title: "New Folder",
                                            help: store.creationDirectory.map { "Create a folder in " + $0.path } ?? "Open a project first") {
                            store.newFolder()
                        }.disabled(store.root == nil)
                    }
                }
            }.padding(.horizontal, 17).padding(.bottom, 8)
            if store.needsFolderAccess { accessNotice }
            ZStack {
                tree(store.index.structure, mode: .structure)
                tree(store.index.subfiles, mode: .subfiles)
                tree(store.index.folders, mode: .folder)
                ResultPanel(store: store)
                    .opacity(store.sidebarMode == .result ? 1 : 0)
                    .allowsHitTesting(store.sidebarMode == .result)
                    .accessibilityHidden(store.sidebarMode != .result)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(LinearGradient(colors: [Palette.sidebarTop, Palette.sidebarBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    /// Shown when macOS refuses to list the project folder, with the fix one click away.
    private var accessNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 11))
                Text("macOS is blocking access to this folder").font(.system(size: 11, weight: .medium))
            }
            Text("QuillTeX can only read the files you picked. Grant access to the folder to load the whole project.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { store.requestFolderAccess() } label: {
                Text("Grant Access…").font(.system(size: 11)).padding(.horizontal, 12).frame(height: 26).quillCapsule()
            }.buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.06)))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
    private var sidebarModes: some View {
        HStack(spacing: 4) {
            ForEach(SidebarMode.allCases) { mode in
                SidebarModeButton(mode: mode, selected: store.sidebarMode == mode) {
                    store.sidebarMode = mode
                }
            }
        }.padding(3).quillCapsule().frame(maxWidth: .infinity)
    }
    private func tree(_ nodes: [NavigationNode], mode: SidebarMode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if store.root == nil {
                    Text("Open a project to browse its navigation").font(.system(size: 12)).foregroundStyle(.tertiary).padding(16)
                } else if nodes.isEmpty {
                    Text(mode == .subfiles ? "No included subfiles" : "Nothing here yet")
                        .font(.system(size: 12)).foregroundStyle(.tertiary).padding(16)
                } else {
                    ForEach(nodes) { node in OutlineRow(node: node, depth: 0, mode: mode, store: store) }
                }
            }.padding(.horizontal, 8).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(store.sidebarMode == mode ? 1 : 0)
        .allowsHitTesting(store.sidebarMode == mode).accessibilityHidden(store.sidebarMode != mode)
    }
}

private struct OutlineRow: View {
    let node: NavigationNode
    let depth: Int
    let mode: SidebarMode
    @ObservedObject var store: ProjectStore
    private var key: String { mode.rawValue + ":" + node.id }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    private var expanded: Bool { store.expandedNodes.contains(key) }
    private var togglesOnRowClick: Bool { node.kind == .folder || node.kind == .group }
    private var icon: String {
        switch node.kind {
        case .group: node.id == "labels" ? "tag" : "list.bullet.rectangle"
        case .section: node.children.isEmpty ? "text.alignleft" : "book.closed"
        case .label: "tag"
        case .figure: "photo"
        case .table: "tablecells"
        case .source: "doc.text"
        case .folder: "folder"
        case .resource:
            node.url?.pathExtension.lowercased() == "pdf" ? "doc.richtext" :
                (["png", "jpg", "jpeg", "eps"].contains(node.url?.pathExtension.lowercased() ?? "") ? "photo" : "doc")
        case .boundary: "text.page"
        case .issue: "exclamationmark.triangle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                if togglesOnRowClick {
                    Button {
                        if node.kind == .folder {
                            store.selectedFolder = node.url
                            store.selectedNodes[mode] = node.id
                        }
                        toggle()
                    } label: {
                        HStack(spacing: 0) {
                            disclosure
                            rowLabel
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(node.children.isEmpty ? "" : (expanded ? "Expanded" : "Collapsed"))
                } else {
                    if !node.children.isEmpty {
                        Button { toggle() } label: { disclosure }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(node.title)")
                            .help("\(expanded ? "Collapse" : "Expand") \(node.title)")
                    } else { disclosure }
                    Button { store.navigate(node) } label: { rowLabel }
                        .buttonStyle(.plain)
                }
            }
            .padding(.leading, CGFloat(min(depth, 12)) * 12 + 3).padding(.trailing, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                store.selectedNodes[mode] == node.id ? Palette.selectionSoft :
                    (hover ? Palette.selectionSoft : .clear)))
            .onHover { hover = $0 }
            .help([node.url.map { store.relativePath($0) }, node.detail].compactMap { $0 }.joined(separator: "\n"))
            .contextMenu {
                if let url = node.url {
                    if mode == .folder, node.kind == .source {
                        Button("Set as Main File") { store.setMainFile(url) }.disabled(url == store.root)
                        Divider()
                    }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    if node.kind == .resource { Button("Open with Default App") { NSWorkspace.shared.open(url) } }
                }
            }
            if expanded && !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.children) { child in OutlineRow(node: child, depth: depth + 1, mode: mode, store: store) }
                }
                .transition(reduceMotion ? .identity : .modifier(
                    active: SidebarBranchReveal(progress: 0), identity: SidebarBranchReveal(progress: 1)))
            }
        }
    }
    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .medium))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .opacity(node.children.isEmpty ? 0 : 1)
            .frame(width: ChromeMetrics.sidebarDisclosureWidth, height: ChromeMetrics.sidebarRowHeight)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
    private var rowLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: node.isMissing ? "exclamationmark.triangle" : icon)
                .font(.system(size: 12)).frame(width: 15).foregroundStyle(Color.black)
            Text(node.title)
                .font(.system(size: 12, weight: node.kind == .group ? .medium : .regular))
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let count = node.count {
                Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
            if node.kind == .source, node.url == store.root {
                Text("Main").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.7))
                    .accessibilityLabel("Main File")
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: ChromeMetrics.sidebarRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
    private func toggle() {
        guard !node.children.isEmpty else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            if expanded { store.expandedNodes.remove(key) } else { store.expandedNodes.insert(key) }
        }
    }
}

/// Reveal a branch at its natural width while smoothly changing its occupied height.
/// Children keep their layout during the transition, rather than stretching or bouncing.
private struct SidebarBranchReveal: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        SidebarBranchLayout(progress: progress) { content }
            .clipped()
            .opacity(progress)
    }
}

private struct SidebarBranchLayout: Layout {
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

private struct SidebarModeButton: View {
    let mode: SidebarMode
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: mode.icon).font(.system(size: 17, weight: selected ? .medium : .regular))
                .foregroundStyle(Color.black)
                .frame(width: 34, height: 34).contentShape(Capsule())
                .background {
                    Capsule().fill(selected ? Color.white : .clear)
                        .overlay(Capsule().strokeBorder(selected ? Color.black.opacity(0.16) : .clear, lineWidth: 0.8))
                        .shadow(color: .black.opacity(selected ? 0.13 : 0), radius: 2.5, y: 1.5)
                }
        }.buttonStyle(.plain)
            .scaleEffect(hover && !reduceMotion ? 1.04 : 1)
            .onHover { hover = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hover)
            .help(mode.rawValue).accessibilityLabel(mode.rawValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarActionButton: View {
    let icon: String
    let title: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black)
                .frame(width: 28, height: 28).contentShape(Circle())
                .background {
                    Circle().fill(Color.white.opacity(hover ? 0.65 : 0.3))
                        .overlay(Circle().strokeBorder(Color.white.opacity(hover ? 0.8 : 0.4), lineWidth: 0.5))
                        .shadow(color: .black.opacity(hover ? 0.06 : 0.02), radius: 2, y: 1)
                }
        }
        .buttonStyle(SidebarActionPressStyle())
        .scaleEffect(hover ? 1.06 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: hover)
        .onHover { hover = $0 }
        .help(title + "\n" + help).accessibilityLabel(title)
    }
}

private struct SidebarActionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
