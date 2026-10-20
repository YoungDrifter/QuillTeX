import SwiftUI
import AppKit

struct ProjectSidebar: View {
    @ObservedObject var store: ProjectStore
    @State private var nameBounds: CGRect?
    var body: some View {
        VStack(spacing: 0) {
            sidebarModes.padding(.top, 12).padding(.bottom, 12)
            if store.sidebarMode != .result {
                HStack {
                    Text(store.sidebarMode.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .onTapGesture { _ = store.commitSidebarNameEdit() }
                    Spacer().frame(height: 28).contentShape(Rectangle())
                        .onTapGesture { _ = store.commitSidebarNameEdit() }
                    if store.isIndexing { ProgressView().controlSize(.mini) }
                    if store.sidebarMode == .folder {
                        SidebarActionButton(icon: "doc.badge.plus", title: "New TeX File",
                                            help: store.creationDirectory.map { "Create a TeX file in " + $0.path } ?? "Open a project first") {
                            store.beginSidebarCreation(folder: false)
                        }.disabled(store.root == nil)
                        SidebarActionButton(icon: "folder.badge.plus", title: "New Folder",
                                            help: store.creationDirectory.map { "Create a folder in " + $0.path } ?? "Open a project first") {
                            store.beginSidebarCreation(folder: true)
                        }.disabled(store.root == nil)
                    }
                }.padding(.horizontal, 17).padding(.bottom, 8)
            }
            if store.needsFolderAccess { accessNotice }
            ZStack {
                tree(store.index.structure, mode: .structure)
                SubfilesList(store: store)
                    .opacity(store.sidebarMode == .subfiles ? 1 : 0)
                    .allowsHitTesting(store.sidebarMode == .subfiles)
                    .accessibilityHidden(store.sidebarMode != .subfiles)
                tree(store.index.folders, mode: .folder)
                ResultPanel(store: store)
                    .opacity(store.sidebarMode == .result ? 1 : 0)
                    .allowsHitTesting(store.sidebarMode == .result)
                    .accessibilityHidden(store.sidebarMode != .result)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(LinearGradient(colors: [Palette.sidebarTop, Palette.sidebarBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        .onChange(of: store.sidebarMode) { _, mode in
            if mode != .folder && !store.commitSidebarNameEdit() { store.sidebarMode = .folder }
        }
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
        .background(RoundedRectangle(cornerRadius: ChromeMetrics.panelCornerRadius).fill(Palette.controlSurface))
        .overlay(RoundedRectangle(cornerRadius: ChromeMetrics.panelCornerRadius).strokeBorder(Palette.hairline))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
    private var sidebarModes: some View {
        ChromeSegmentedGroup(selection: store.sidebarMode) { modeSelection in
            ForEach(SidebarMode.allCases) { mode in
                SidebarModeButton(mode: mode, selected: store.sidebarMode == mode, selectionNamespace: modeSelection) {
                    store.sidebarMode = mode
                }
            }
        }.padding(3).quillCapsule()
            .frame(maxWidth: 220).padding(.horizontal, 10).frame(maxWidth: .infinity)
    }
    private func tree(_ nodes: [NavigationNode], mode: SidebarMode) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if store.root == nil {
                    Text("Open a project to browse its navigation").font(.system(size: 12)).foregroundStyle(.tertiary).padding(16)
                } else if nodes.isEmpty {
                    Text(mode == .subfiles ? "No included subfiles" : "Nothing here yet")
                        .font(.system(size: 12)).foregroundStyle(.tertiary).padding(16)
                } else {
                    ForEach(nodes) { node in OutlineRow(node: node, depth: 0, mode: mode, store: store).id(node.id) }
                }
            }.padding(.horizontal, 8).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: mode.rawValue + "Rows")
        .onPreferenceChange(SidebarNameBounds.self) { if mode == .folder { nameBounds = $0 } }
        .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(mode.rawValue + "Rows")).onEnded { value in
            guard mode == .folder, store.sidebarNameEdit != nil,
                  nameBounds?.contains(value.location) != true else { return }
            _ = store.commitSidebarNameEdit()
        })
        .onChange(of: store.sidebarNameEdit?.id) { _, _ in
            guard mode == .folder, let edit = store.sidebarNameEdit else { return }
            let rowID = edit.isCreation ? edit.placeholderID : "file:" + (edit.originalURL?.path ?? "")
            DispatchQueue.main.async { proxy.scrollTo(rowID, anchor: .center) }
        }
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
    private var children: [NavigationNode] { mode == .folder ? store.sidebarChildren(of: node) : node.children }
    private var isNaming: Bool { mode == .folder && store.sidebarIsNaming(node) }
    private var key: String {
        if mode == .folder, node.kind == .folder, let url = node.url { return ProjectStore.folderExpansionKey(url) }
        return mode.rawValue + ":" + node.id
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    private var isRootFolder: Bool { mode == .folder && node.kind == .folder && node.url.map(store.isProjectRootFolder) == true }
    private var expanded: Bool { isRootFolder || store.expandedNodes.contains(key) }
    private var togglesOnRowClick: Bool { node.kind == .folder || node.kind == .group }
    private var icon: String {
        switch node.kind {
        case .group: node.id == "labels" ? "tag" : "list.bullet.rectangle"
        case .section: children.isEmpty ? "text.alignleft" : "book.closed"
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
                if isNaming {
                    if !isRootFolder { disclosure }
                    rowLabel
                } else if isRootFolder {
                    Button { if let url = node.url { store.toggleFolder(url) } } label: {
                        rowLabel
                    }.buttonStyle(.plain)
                } else if togglesOnRowClick {
                    Button {
                        toggle()
                    } label: {
                        HStack(spacing: 0) {
                            disclosure
                            rowLabel
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                } else {
                    if !children.isEmpty {
                        Button { toggle() } label: { disclosure }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(node.title)")
                            .help("\(expanded ? "Collapse" : "Expand") \(node.title)")
                    } else { disclosure }
                    Button { store.navigate(node) } label: { rowLabel }
                        .buttonStyle(.plain)
                }
            }
            .padding(.leading, CGFloat(min(depth, 12)) * (mode == .folder ? ChromeMetrics.sidebarIconWidth : 12) + 3).padding(.trailing, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                store.selectedNodes[mode] == node.id ? Palette.primaryInk.opacity(Palette.selectedOpacity) :
                    Palette.primaryInk.opacity(hover ? Palette.chromeHoverOpacity : 0)))
            .onHover { hover = $0 }
            .help([node.url.map { store.relativePath($0) }, node.detail].compactMap { $0 }.joined(separator: "\n"))
            .modifier(FolderRowActions(node: node, mode: mode, store: store))
            .contextMenu {
                if let url = node.url {
                    if mode != .folder {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        if node.kind == .resource { Button("Open with Default App") { NSWorkspace.shared.open(url) } }
                    }
                }
            }
            if expanded && !children.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(children) { child in OutlineRow(node: child, depth: isRootFolder ? depth : depth + 1, mode: mode, store: store).id(child.id) }
                }
                .transition(reduceMotion ? .identity : .modifier(
                    active: QuillBranchReveal(progress: 0), identity: QuillBranchReveal(progress: 1)))
            }
        }
    }
    private var disclosure: some View {
        QuillSidebarDisclosure(expanded: expanded)
            .opacity(children.isEmpty && node.kind != .folder ? 0 : 1)
    }
    private var rowLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: node.isMissing ? "exclamationmark.triangle" : icon)
                .font(.system(size: 12)).frame(width: ChromeMetrics.sidebarIconWidth).foregroundStyle(Palette.primaryInk)
            if isNaming, let edit = store.sidebarNameEdit {
                SidebarInlineNameEditor(store: store, id: edit.id).layoutPriority(1)
            } else {
                Text(node.title)
                    .font(.system(size: 12, weight: node.kind == .group ? .medium : .regular))
                    .multilineTextAlignment(.leading).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let count = node.count {
                Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
            if node.kind == .source, node.url == store.root {
                Text("Main").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.primaryInk)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.controlSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.7))
                    .accessibilityLabel("Main File")
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: ChromeMetrics.sidebarRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
    private func toggle() {
        guard !children.isEmpty || node.kind == .folder else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            if node.kind == .folder, let url = node.url { store.toggleFolder(url) }
            else if expanded { store.expandedNodes.remove(key) } else { store.expandedNodes.insert(key) }
        }
    }
}

private struct SubfileDropBounds: PreferenceKey {
    static let defaultValue: [ProjectStore.SubfilePlacement: CGRect] = [:]
    static func reduce(value: inout [ProjectStore.SubfilePlacement: CGRect], nextValue: () -> [ProjectStore.SubfilePlacement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SubfilesList: View {
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
                Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
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

private struct FolderRowActions: ViewModifier {
    let node: NavigationNode
    let mode: SidebarMode
    @ObservedObject var store: ProjectStore
    @State private var showing = false
    @State private var deleting = false

    @ViewBuilder func body(content: Content) -> some View {
        if mode == .folder, store.sidebarMode == .folder, !store.sidebarIsNaming(node), let url = node.url {
            content
                .overlay(SidebarSecondaryClick {
                    deleting = false
                    showing = true
                }.accessibilityHidden(true))
                .accessibilityAction(named: Text("File Actions")) { deleting = false; showing = true }
                .popover(isPresented: $showing, arrowEdge: .trailing) {
                    Group {
                        if deleting {
                            SidebarTrashForm(store: store, url: url) { showing = false }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                if node.kind == .folder {
                                    action("New Subfile", icon: "doc.badge.plus") {
                                        showing = false
                                        DispatchQueue.main.async { store.beginSidebarCreation(folder: false, in: url) }
                                    }
                                    action("New Folder", icon: "folder.badge.plus") {
                                        showing = false
                                        DispatchQueue.main.async { store.beginSidebarCreation(folder: true, in: url) }
                                    }
                                }
                                if node.kind == .source || node.kind == .resource {
                                    action("Rename", icon: "pencil") {
                                        showing = false
                                        DispatchQueue.main.async { store.beginSidebarRename(url) }
                                    }
                                    action("Move to Trash", icon: "trash") { deleting = true }
                                }
                                action("Reveal in Finder", icon: "folder") {
                                    showing = false; NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                                if node.kind == .resource {
                                    action("Open with Default App", icon: "arrow.up.forward.app") {
                                        showing = false; NSWorkspace.shared.open(url)
                                    }
                                }
                            }.frame(width: contextMenuWidth)
                        }
                    }.quillPopoverContent(padding: deleting ? ChromeMetrics.panelPadding : 8)
                }
        } else { content }
    }

    private var contextMenuWidth: CGFloat {
        var titles = ["Reveal in Finder"]
        if node.kind == .folder { titles += ["New Subfile", "New Folder"] }
        if node.kind == .source || node.kind == .resource { titles += ["Rename", "Move to Trash"] }
        if node.kind == .resource { titles.append("Open with Default App") }
        let longest = titles.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width }.max() ?? 0
        return ceil(min(240, max(160, longest + 48)))
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .regular))
                .foregroundStyle(Palette.secondaryInk).frame(width: 18, height: 18)
            Text(title).font(.system(size: 13))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.primaryInk)
        .padding(.horizontal, 10).frame(height: 30)
        .contentShape(Rectangle())
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { actionLabel(title, icon: icon) }
            .buttonStyle(QuillRowButtonStyle())
    }
}

private struct SidebarTrashForm: View {
    @ObservedObject var store: ProjectStore
    let url: URL
    let onClose: () -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuillPopoverTitle("Move to Trash")
            Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
            Text("The file will be moved to the Trash.").font(.system(size: 12)).foregroundStyle(.secondary)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: apply).keyboardShortcut(.defaultAction)
            }.buttonStyle(SettingsActionStyle())
        }.frame(width: ChromeMetrics.popoverWidth)
    }
    private func apply() {
        do { if try store.trashProjectFile(url) { onClose() } }
        catch { self.error = error.localizedDescription }
    }
}

private struct SidebarNameBounds: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}

private struct SidebarInlineNameEditor: View {
    @ObservedObject var store: ProjectStore
    let id: UUID
    var body: some View {
        HStack(spacing: 4) {
            SidebarNameField(store: store, id: id).frame(height: 23)
            if let error = store.sidebarNameEdit?.error {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.secondary).help(error)
            }
        }.background(GeometryReader { geometry in
            Color.clear.preference(key: SidebarNameBounds.self,
                value: geometry.frame(in: .named(SidebarMode.folder.rawValue + "Rows")))
        })
    }
}

private struct SidebarNameField: NSViewRepresentable {
    let store: ProjectStore
    let id: UUID
    func makeCoordinator() -> Coordinator { Coordinator(store: store, id: id) }
    func makeNSView(context: Context) -> NameField {
        let field = NameField()
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.isBordered = false; field.isBezeled = false
        field.drawsBackground = true; field.backgroundColor = .white
        field.focusRingType = .none
        field.wantsLayer = true; field.layer?.cornerRadius = 4
        field.layer?.borderWidth = 0.7; field.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.25).cgColor
        field.delegate = context.coordinator
        field.setAccessibilityLabel("File name")
        field.setAccessibilityIdentifier("sidebarNameEditor")
        field.onAttach = { [weak field, weak store] in
            DispatchQueue.main.async {
                guard let field, let edit = store?.sidebarNameEdit, edit.id == id, let window = field.window else { return }
                window.makeFirstResponder(field)
                let selected = edit.kind == .folder ? edit.text : (edit.text as NSString).deletingPathExtension
                (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: selected.utf16.count))
            }
        }
        return field
    }
    func updateNSView(_ field: NameField, context: Context) {
        guard let edit = store.sidebarNameEdit, edit.id == id else { return }
        if field.stringValue != edit.text { field.stringValue = edit.text }
        field.toolTip = edit.error
    }
    static func dismantleNSView(_ field: NameField, coordinator: Coordinator) { field.delegate = nil }
    final class NameField: NSTextField {
        var onAttach: (() -> Void)?
        private var requestedFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil && !requestedFocus { requestedFocus = true; onAttach?() }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var store: ProjectStore?
        let id: UUID
        init(store: ProjectStore, id: UUID) { self.store = store; self.id = id; super.init() }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            store?.updateSidebarName(field.stringValue, id: id)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field)
        }
        private func finish(_ field: NSTextField) {
            guard let store, store.sidebarNameEdit?.id == id else { return }
            store.updateSidebarName(field.stringValue, id: id)
            if !store.commitSidebarNameEdit(id: id) {
                DispatchQueue.main.async { [weak field, weak store] in
                    guard store?.sidebarNameEdit?.id == self.id, let field else { return }
                    field.window?.makeFirstResponder(field)
                }
            }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(commandSelector) {
            case "insertNewline:":
                if let field = control as? NSTextField { finish(field) }
                return true
            case "cancelOperation:":
                store?.cancelSidebarNameEdit(id: id)
                return true
            default: return false
            }
        }
    }
}

/// Capture only secondary clicks; normal row selection, disclosure and scrolling
/// continue to reach SwiftUI underneath the transparent overlay.
private struct SidebarSecondaryClick: NSViewRepresentable {
    let onOpen: () -> Void
    func makeNSView(context: Context) -> SidebarSecondaryClickView { SidebarSecondaryClickView() }
    func updateNSView(_ view: SidebarSecondaryClickView, context: Context) { view.onOpen = onOpen }
}

private final class SidebarSecondaryClickView: NSView {
    var onOpen: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)), !isHiddenOrHasHiddenAncestor,
              let event = NSApp.currentEvent else { return nil }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onOpen?() }
    override func mouseDown(with event: NSEvent) { onOpen?() }
}

private struct SidebarModeButton: View {
    let mode: SidebarMode
    let selected: Bool
    let selectionNamespace: Namespace.ID
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: mode.icon)
                .font(.system(size: ChromeMetrics.chromeIconSize, weight: .regular))
                .frame(maxWidth: .infinity).frame(height: 34).contentShape(Capsule())
        }
        .buttonStyle(ChromeButtonStyle(selected: selected, selectionNamespace: selectionNamespace))
        .modifier(ChromeHoverFeedback(selected: selected))
        .help(mode.rawValue).accessibilityLabel(mode.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarActionButton: View {
    let icon: String
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.primaryInk)
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(ChromeButtonStyle())
        .modifier(ChromeHoverFeedback())
        .help(title + "\n" + help).accessibilityLabel(title)
    }
}
