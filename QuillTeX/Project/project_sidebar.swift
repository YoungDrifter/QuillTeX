import SwiftUI
import AppKit

struct ProjectSidebar: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var catalog = DocumentCatalog.shared
    @ObservedObject private var settingsNavigation = SettingsNavigation.shared
    @State private var nameBounds: CGRect?
    /// Page 1 is the library, page 2 the project outline (or Settings
    /// categories). Paging only exists while a document or the Settings tab is
    /// active: the library home and New Tab page are single-page surfaces, even
    /// when a document stays open in another tab.
    private var hasPages: Bool {
        if store.isEditingTemplate { return false }
        return store.showingSettings || (store.root != nil && !store.showingLibrary)
    }
    private var pageIndex: Int { hasPages && store.sidebarPage == .structure ? 1 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            SidebarNavigationHeader(store: store)
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if hasPages {
                        // Page 1 is the document library, page 2 is the project
                        // navigation. Opening a document lands on page 2.
                        HStack(spacing: 0) {
                            libraryPage
                                .padding(.bottom, 24)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                            Group {
                                if store.showingSettings {
                                    settingsPage
                                } else {
                                    structurePage
                                }
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            // Composite the project page before moving the strip so its
                            // animated selection stays inside the page's own clip.
                            .clipped()
                            .compositingGroup()
                        }
                        .offset(x: -CGFloat(pageIndex) * geometry.size.width)
                        .animation(.smooth(duration: 0.26), value: pageIndex)
                    } else {
                        libraryPage.frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .background(SidebarPageSwipeMonitor { direction in
                    guard hasPages else { return }
                    store.sidebarPage = direction > 0 ? .structure : .library
                })
            }
            .overlay(alignment: .bottom) {
                if hasPages {
                    SidebarPageIndicator(store: store).padding(.bottom, 8)
                }
            }
        }
        .background(SidebarBackdrop())
        .onChange(of: store.sidebarMode) { _, mode in
            if mode != .folder && !store.commitSidebarNameEdit() { store.sidebarMode = .folder }
        }
    }

    // MARK: - Page 1: document library

    private var libraryPage: some View {
        LibrarySidebarContent(store: store, catalog: catalog,
                              onNew: { store.openNewDocumentSheet() },
                              onOpen: { store.openPanel() },
                              onOpenEntry: { store.openLibraryEntry($0) })
    }

    // MARK: - Page 2: Settings categories

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .center, spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1.5)
                Text("QuillTeX")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.primaryInk)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.1") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "68"))")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryInk)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
            ForEach(SettingsSection.allCases.filter { $0 != .about }) { section in
                let selected = settingsNavigation.section == section
                Button {
                    settingsNavigation.section = section
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 13))
                            .frame(width: ChromeMetrics.sidebarIconWidth)
                        Text(section.title)
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selected ? Palette.primaryInk : Palette.secondaryInk)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.primaryInk.opacity(selected ? 0.09 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 22)
    }

    // MARK: - Page 2: project navigation

    private var structurePage: some View {
        VStack(spacing: 0) {
            DocumentSidebarHeader(store: store)
            SidebarModePicker(store: store, animatesSelection: pageIndex == 1)
                .padding(.top, 8).padding(.bottom, 12)
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
                if store.texProjectEnabled {
                TeXProjectList(store: store)
                    .opacity(store.sidebarMode == .tex ? 1 : 0)
                    .allowsHitTesting(store.sidebarMode == .tex)
                    .accessibilityHidden(store.sidebarMode != .tex)
                }
                tree(store.index.folders, mode: .folder)
                ResultPanel(store: store)
                    .opacity(store.sidebarMode == .result ? 1 : 0)
                    .allowsHitTesting(store.sidebarMode == .result)
                    .accessibilityHidden(store.sidebarMode != .result)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Leave room for the floating page indicator at the sidebar's bottom edge.
        .padding(.bottom, 22)
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
    private func tree(_ nodes: [NavigationNode], mode: SidebarMode) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if store.root == nil {
                    Text("Open a project to browse its navigation").font(.system(size: 12)).foregroundStyle(.tertiary).padding(16)
                } else if nodes.isEmpty {
                    Text(mode == .tex ? "No TeX files" : "Nothing here yet")
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

/// The window-control row: traffic lights on the left, the sidebar toggle at the
/// top-right of the sidebar (no history navigation).
private struct SidebarNavigationHeader: View {
    @ObservedObject var store: ProjectStore

    private var hideSidebar: () -> Void { { store.sidebarVisible = false } }

    var body: some View {
        HStack(spacing: 0) {
            if store.isFullScreen {
                // Full screen has no traffic lights, so the collapse control moves
                // to the sidebar's top-left corner where the window buttons were.
                ChromeButton(icon: "sidebar.left", label: "Hide Sidebar", action: hideSidebar)
                    .padding(.leading, 8)
                Spacer(minLength: 0)
            } else {
                Color.clear.frame(width: ChromeMetrics.controlsInset)
                Spacer(minLength: 0)
                ChromeButton(icon: "sidebar.left", label: "Hide Sidebar", action: hideSidebar)
            }
        }
        .padding(.trailing, 8)
        .frame(height: ChromeMetrics.topBarHeight)
        .contentShape(Rectangle())
    }
}

/// Page 2's document header: the compiled page thumbnail, the document name and
/// how long ago it was last saved.
private struct DocumentSidebarHeader: View {
    @ObservedObject var store: ProjectStore
    private var mainDocument: SourceDocument? {
        guard let root = store.root else { return nil }
        return store.documents.first { $0.url.standardizedFileURL == root.standardizedFileURL }
    }
    private var title: String {
        guard let root = store.root else { return "Document" }
        return store.projectTitle(for: root)
    }
    private var lastModified: Date? {
        guard let main = store.root else { return nil }
        if let document = mainDocument, document.isDirty { return Date() }
        return (try? main.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    private var relativeTime: String {
        guard let date = lastModified else { return "Not saved yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    private var entry: LibraryEntry? {
        guard let root = store.root else { return nil }
        return LibraryEntry(path: root.path, displayName: title,
                            kind: root.lastPathComponent == "main.tex" ? .project : .file)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let entry {
                    LibraryDocumentThumbnail(entry: entry, size: CGSize(width: 34, height: 42), cornerRadius: 7)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 34, height: 42)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 0.6))
                        .overlay(Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(Palette.secondaryInk))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.primaryInk)
                        .lineLimit(1).truncationMode(.middle)
                    Text(relativeTime)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Rectangle().fill(Palette.hairline).frame(height: 1)
                .padding(.horizontal, 12)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let root = store.root {
                Button("Rename Project…") { store.requestRenameProject(root) }
            }
        }
    }
}

/// Two dots at the sidebar's bottom edge: page 1 is the library, page 2 the project.
private struct SidebarPageIndicator: View {
    @ObservedObject var store: ProjectStore
    private var pageIndex: Int { store.sidebarPage == .structure ? 1 : 0 }
    var body: some View {
        HStack(spacing: 6) {
            dot(0)
            dot(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 20)
        .background(Capsule().fill(Color.white.opacity(0.92)))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 1)
        .help("Switch between the library and the project")
    }
    private func dot(_ index: Int) -> some View {
        Button {
            store.sidebarPage = index == 0 ? .library : .structure
        } label: {
            Circle().fill(index == pageIndex ? Palette.primaryInk : Palette.secondaryInk.opacity(0.35))
                .frame(width: 6, height: 6)
                .frame(width: 14, height: 14)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(index == 0 ? "Library" : "Project")
        .accessibilityLabel(index == 0 ? "Library page" : "Project page")
        .accessibilityAddTraits(index == pageIndex ? .isSelected : [])
    }
}

/// A horizontal two-finger swipe over the sidebar switches its two pages. It
/// observes scroll-wheel events locally so the vertical scroll views inside the
/// sidebar keep working unchanged.
private struct SidebarPageSwipeMonitor: NSViewRepresentable {
    let onSwipe: (Int) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = SidebarPageSwipeView()
        view.onSwipe = onSwipe
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SidebarPageSwipeView)?.onSwipe = onSwipe
    }
}

private final class SidebarPageSwipeView: NSView {
    var onSwipe: ((Int) -> Void)?
    private var monitor: Any?
    private var accumulated: CGFloat = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  event.phase == .began || self.accumulated != 0 || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
                return event
            }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            if event.phase == .began { self.accumulated = 0 }
            self.accumulated += event.scrollingDeltaX
            if event.phase == .ended || event.momentumPhase == .ended || event.phase == .cancelled {
                if abs(self.accumulated) > 30 { self.onSwipe?(self.accumulated < 0 ? 1 : -1) }
                self.accumulated = 0
            }
            return event
        }
    }
    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        accumulated = 0
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
                        if node.kind != .resource, let root = store.root {
                            Button("Rename Project…") { store.requestRenameProject(root) }
                        }
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
                                if node.kind == .source, let root = store.root {
                                    action("Rename Project…", icon: "pencil") {
                                        showing = false
                                        DispatchQueue.main.async { store.requestRenameProject(root) }
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
                            }
                            .frame(minWidth: 160)
                            .fixedSize(horizontal: true, vertical: true)
                        }
                    }.quillPopoverContent(padding: deleting ? ChromeMetrics.panelPadding : 8)
                }
        } else { content }
    }

    private func actionLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13, weight: .regular))
                .foregroundStyle(Palette.secondaryInk).frame(width: 18, height: 18)
            Text(title).font(.system(size: 13))
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.primaryInk)
        .padding(.horizontal, 10).frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Move to Trash", action: apply).keyboardShortcut(.defaultAction)
            }.buttonStyle(SettingsActionStyle())
        }.frame(width: ChromeMetrics.popoverWidth)
    }
    private func apply() {
        // Run after the button action so the close confirmation can present
        // without blocking SwiftUI's update pass.
        DispatchQueue.main.async {
            do { if try store.trashProjectFile(url) { onClose() } }
            catch { self.error = error.localizedDescription }
        }
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

struct SidebarModePicker: View {
    @ObservedObject var store: ProjectStore
    var animatesSelection = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var modes: [SidebarMode] { SidebarMode.allCases.filter { $0 != .tex || store.texProjectEnabled } }
    var body: some View {
        ChromeSegmentedGroup(selection: store.sidebarMode) { selection in
            ForEach(modes) { mode in
                SidebarModeButton(mode: mode, selected: store.sidebarMode == mode, selectionNamespace: animatesSelection ? selection : nil) {
                    store.sidebarMode = mode
                }
            }
        }
        // End any in-flight selection animation when the project page leaves.
        .id(animatesSelection)
        .transition(.identity)
        .padding(3).quillCapsule()
        .clipped()
        .compositingGroup()
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : ChromeMotion.feedback, value: modes.count)
        .padding(.horizontal, 10)
    }
}

private struct SidebarModeButton: View {
    let mode: SidebarMode
    let selected: Bool
    let selectionNamespace: Namespace.ID?
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
