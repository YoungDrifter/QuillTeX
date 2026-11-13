import SwiftUI

private struct TeXRoleBounds: PreferenceKey {
    static let defaultValue: [ProjectStore.TeXFileRole: CGRect] = [:]
    static func reduce(value: inout [ProjectStore.TeXFileRole: CGRect], nextValue: () -> [ProjectStore.TeXFileRole: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TeXProjectList: View {
    @ObservedObject private var plugins = PluginManager.shared
    @ObservedObject var store: ProjectStore
    @State private var dragged: URL?
    @State private var target: ProjectStore.TeXFileRole?
    @State private var bounds: [ProjectStore.TeXFileRole: CGRect] = [:]
    @State private var expanded = Dictionary(uniqueKeysWithValues: ProjectStore.TeXFileRole.allCases.map { ($0, true) })
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                roleGroup(.main, files: store.mainTeXFiles)
                roleGroup(.sub, files: store.subTeXFiles)
                roleGroup(.other, files: store.otherTeXFiles)
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
            .coordinateSpace(name: "texRoleList")
            .onPreferenceChange(TeXRoleBounds.self) { bounds = $0 }
        }
        .onDisappear { dragged = nil; target = nil }
    }

    private func roleGroup(_ role: ProjectStore.TeXFileRole, files: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded[role, default: true].toggle() }
            } label: {
                HStack(spacing: 7) {
                    QuillSidebarDisclosure(expanded: expanded[role, default: true])
                    Text(role.rawValue).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                    Text("\(files.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .foregroundStyle(Palette.primaryInk).padding(.leading, 3).padding(.trailing, 6)
                .frame(height: ChromeMetrics.sidebarRowHeight).contentShape(Rectangle())
            }
            .buttonStyle(QuillRowButtonStyle())
            .accessibilityValue(expanded[role, default: true] ? "Expanded" : "Collapsed")

            if expanded[role, default: true] {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.self) { row($0, role: role) }
                    if files.isEmpty {
                        Text(emptyText(role)).font(.system(size: 12)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 10).frame(height: ChromeMetrics.sidebarRowHeight)
                    }
                }
                .transition(reduceMotion ? .identity : .modifier(
                    active: QuillBranchReveal(progress: 0), identity: QuillBranchReveal(progress: 1)))
            }
        }
        .padding(.vertical, 3)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: TeXRoleBounds.self,
                                   value: [role: geometry.frame(in: .named("texRoleList"))])
        })
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Palette.primaryInk.opacity(target == role ? 0.35 : 0), lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Palette.primaryInk.opacity(target == role ? 0.045 : 0)))
                .allowsHitTesting(false)
        }
    }

    private func row(_ url: URL, role: ProjectStore.TeXFileRole) -> some View {
        Button { if dragged == nil { store.openSource(url) } } label: {
            HStack(spacing: 7) {
                Image(systemName: role == .main ? "scope" : "doc.text")
                    .font(.system(size: 12)).frame(width: ChromeMetrics.sidebarIconWidth)
                Text(plugins.option("extensions", for: PluginManager.texProjectID)
                     ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 3).padding(.trailing, 6).frame(minHeight: ChromeMetrics.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuillRowButtonStyle(selected: store.activeDocument?.url == url))
        .opacity(dragged == url ? 0.45 : 1)
        .help(store.relativePath(url))
        .contextMenu {
            if let root = store.root {
                Button("Rename Project…") { store.requestRenameProject(root) }
            }
        }
        .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("texRoleList"))
            .onChanged { value in
                dragged = url
                target = bounds.first(where: { $0.value.contains(value.location) })?.key
            }
            .onEnded { value in
                target = bounds.first(where: { $0.value.contains(value.location) })?.key
                defer { dragged = nil; target = nil }
                guard let target, target != role else { return }
                change(url, to: target)
            })
        .accessibilityAction(named: Text("Move to Main")) { change(url, to: .main) }
        .accessibilityAction(named: Text("Move to Sub")) { change(url, to: .sub) }
        .accessibilityAction(named: Text("Move to Others")) { change(url, to: .other) }
    }

    private func change(_ url: URL, to role: ProjectStore.TeXFileRole) {
        do { try store.setTeXFile(url, role: role) }
        catch { store.showError("Could Not Change TeX Relationship", error.localizedDescription) }
    }

    private func emptyText(_ role: ProjectStore.TeXFileRole) -> String {
        switch role {
        case .main: "No main file"
        case .sub: "No related TeX files"
        case .other: "No other TeX files"
        }
    }
}
