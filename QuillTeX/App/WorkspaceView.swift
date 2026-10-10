import SwiftUI
import AppKit
import Combine

struct WorkspaceView: View {
    @StateObject private var store = ProjectStore()
    @Environment(\.openWindow) private var openWindow
    var openURL: URL? = nil
    private var isWelcome: Bool { store.root == nil }
    var body: some View {
        VStack(spacing: 0) {
            if store.root == nil {
                WelcomeView(store: store, library: store.library)
            } else {
                TopBar(store: store)
                WorkspaceSplit(store: store)
            }
        }
        .frame(minWidth: isWelcome ? ChromeMetrics.welcomeMinimumSize.width : ChromeMetrics.workspaceMinimumSize.width,
               minHeight: isWelcome ? ChromeMetrics.welcomeMinimumSize.height : ChromeMetrics.workspaceMinimumSize.height)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
        .background(WindowConnection(store: store))
        .focusedSceneObject(store)
         .sheet(isPresented: $store.showLibrary) { WelcomeView(store: store, library: store.library, isSheet: true).frame(width: 880, height: 560) }
        .sheet(isPresented: Binding(get: { store.showTemplateChooser && store.root != nil && !store.showLibrary }, set: { store.showTemplateChooser = $0 })) { TemplateChooser(store: store, library: store.library) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.checkExternalChanges(); store.library.reloadTemplates() }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            // SwiftUI owns the application delegate and can deliver Finder opens
            // through this scene rather than the legacy AppKit openFiles callback.
            if store.root == nil { store.openProject(url) }
            else { AppDelegate.openDocuments([url]) }
        }
        .onAppear {
            AppDelegate.openWorkspace = { url in openWindow(id: "workspace", value: url) }
            if store.root == nil, let openURL { store.openProject(openURL) }

            if AppDelegate.pendingNewDocument {
                AppDelegate.pendingNewDocument = false; store.showTemplateChooser = true
            }
            let pending = AppDelegate.pendingOpenURLs
            AppDelegate.pendingOpenURLs = []
            for url in pending {
                if store.root == nil { store.openProject(url) }
                else { openWindow(id: "workspace", value: url) }
            }
            if let folder = AppDelegate.pendingOpenPanel {
                AppDelegate.pendingOpenPanel = nil
                DispatchQueue.main.async { store.openPanel(folder: folder) }
            }
            // The command-line document belongs to the launch window only. Reading it
            // here on every appearance made each new window reopen the same project.
            if store.root == nil, let url = AppDelegate.consumeLaunchDocument() { store.openProject(url) }
        }
    }
}

private struct EditorPane: View {
    @ObservedObject var store: ProjectStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EditorBreadcrumb(store: store)
                Spacer(minLength: 8)
                if let document = store.activeDocument { EditorHistoryButtons(document: document) }
            }.padding(.horizontal, 12).frame(height: ChromeMetrics.paneHeaderHeight).background(Palette.topBar)
            Divider()
            if let document = store.activeDocument {
                SourceEditor(document: document, store: store).id(document.id)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "text.book.closed").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.tertiary)
                    Text("Start with a document").font(.system(size: 19, weight: .medium))
                    Text("Open a main .tex file to keep writing.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button { store.openPanel() } label: {
                        Text("Open LaTeX File…").padding(.horizontal, 18).frame(height: 34).quillCapsule()
                    }.buttonStyle(.plain).padding(.top, 4)
                    Text("⌘O").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
            }
        }
    }
}

private struct EditorHistoryButtons: View {
    @ObservedObject var document: SourceDocument
    var body: some View {
        HStack(spacing: 2) {
            historyButton("arrow.uturn.backward", title: "Undo", shortcut: "⌘Z", enabled: document.undoManager.canUndo) {
                document.undoManager.undo()
            }
            historyButton("arrow.uturn.forward", title: "Redo", shortcut: "⇧⌘Z", enabled: document.undoManager.canRedo) {
                document.undoManager.redo()
            }
        }.padding(2).quillCapsule()
    }
    private func historyButton(_ icon: String, title: String, shortcut: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            guard let editor = document.editorSurface?.textView else { return }
            editor.window?.makeFirstResponder(editor)
            editor.breakUndoCoalescing()
            action()
        } label: {
            Image(systemName: icon).font(.system(size: 13))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(EditorHistoryStyle()).disabled(!enabled)
        .help("\(title) (\(shortcut))").accessibilityLabel(title)
    }
}
private struct EditorHistoryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        EditorHistoryLabel(label: configuration.label, pressed: configuration.isPressed)
    }
}
private struct EditorHistoryLabel<Label: View>: View {
    let label: Label
    let pressed: Bool
    @State private var hovered = false
    var body: some View {
        label.background(Capsule().fill(Color.black.opacity(pressed ? 0.10 : (hovered ? 0.05 : 0))))
            .onHover { hovered = $0 }
    }
}

/// TeXifier-style path breadcrumb: main file › folders › current file. Every segment
/// opens the contents of its folder, so the whole project is one click away.
private struct EditorBreadcrumb: View {
    @ObservedObject var store: ProjectStore

    private var active: URL? { store.activeDocument?.url }

    /// The folders between the main file's folder and the file being edited.
    private var folders: [URL] {
        guard let base = store.directory?.standardizedFileURL, let active else { return [] }
        var result: [URL] = []
        var url = active.deletingLastPathComponent().standardizedFileURL
        while url.path.count > base.path.count, url.path.hasPrefix(base.path + "/") {
            result.insert(url, at: 0)
            url = url.deletingLastPathComponent()
        }
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            if let main = store.root {
                // The leading mark stays where it is; the chain beside it scrolls, so a
                // deep path or a very long file name can never widen the editor pane
                // (which used to squeeze the preview).
                Image(systemName: "scope")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 25)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 1) {
                        segment(main, icon: "scope", current: active == main, parents: true, showsIcon: false)
                        ForEach(folders, id: \.self) { folder in
                            separator
                            segment(folder, icon: "folder", current: false)
                        }
                        if let active, active != main {
                            separator
                            segment(active, icon: "doc.text", current: true)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("QuillTeX").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
    private var separator: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary).padding(.horizontal, 1)
    }
    /// The project folder and every folder above it, closest first, so the first
    /// segment can offer the same parent-folder jump as the reference editor.
    private var ancestors: [URL] {
        guard let directory = store.directory?.standardizedFileURL else { return [] }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        var result: [URL] = []
        var url = directory
        while true {
            result.append(url)
            if url.path == home.path || url.path == "/" { break }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if parent.path == url.path { break }
            url = parent
        }
        return result
    }

    private func segment(_ url: URL, icon: String, current: Bool, parents: Bool = false, showsIcon: Bool = true) -> some View {
        Menu {
            if parents {
                ForEach(ancestors, id: \.self) { folder in
                    Button {
                        store.openFolder(folder)
                    } label: {
                        Label(folder == store.directory ? "\(folder.lastPathComponent) (current project)" : folder.lastPathComponent,
                              systemImage: folder == store.directory ? "folder.fill" : "folder")
                    }
                }
            } else {
                FolderContentsMenu(store: store, folder: url.deletingLastPathComponent())
            }
        } label: {
            HStack(spacing: 5) {
                if showsIcon { Image(systemName: icon).font(.system(size: 11)).frame(width: 14) }
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12, weight: current ? .medium : .regular)).lineLimit(1)
            }
            .foregroundStyle(current ? Color.primary : Color.secondary)
            .padding(.horizontal, 7).frame(height: 25)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(store.relativePath(url))
    }
}

/// The project folder as a menu: subfolders nest, `.tex` files open in the editor.
private struct FolderContentsMenu: View {
    @ObservedObject var store: ProjectStore
    let folder: URL

    var body: some View {
        let nodes = children
        if nodes.isEmpty {
            Text("Empty").foregroundStyle(.secondary)
        } else {
            ForEach(nodes) { node in
                if node.kind == .folder, let url = node.url {
                    Menu(url.lastPathComponent) { FolderContentsMenu(store: store, folder: url) }
                } else if let url = node.url {
                    Button {
                        store.openSource(url)
                    } label: {
                        Label(url.lastPathComponent,
                              systemImage: store.activeDocument?.url == url ? "checkmark" : "doc.text")
                    }
                }
            }
        }
    }

    /// Read from the background index: no disk work while a menu is opening.
    private var children: [NavigationNode] {
        func search(_ list: [NavigationNode]) -> [NavigationNode]? {
            for node in list {
                if node.kind == .folder, let url = node.url, url.standardizedFileURL == folder.standardizedFileURL {
                    return node.children
                }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return (search(store.index.folders) ?? []).filter { node in
            guard node.kind == .folder || node.kind == .source else { return false }
            return node.url?.pathExtension.lowercased() == "tex" || node.kind == .folder
        }
    }
}

private struct WorkspaceSplit: NSViewControllerRepresentable {
    @ObservedObject var store: ProjectStore
    func makeNSViewController(context: Context) -> WorkspaceSplitController {
        WorkspaceSplitController(sidebar: NSHostingController(rootView: ProjectSidebar(store: store)),
                                 editor: NSHostingController(rootView: EditorPane(store: store)),
                                 preview: NSHostingController(rootView: PreviewPane(store: store)),
                                 tabBar: NSHostingController(rootView: FileTabBar(store: store)))
    }
    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
        controller.update(sidebarVisible: store.sidebarVisible, paneMode: store.paneMode,
                          splitLayoutVersion: store.splitLayoutVersion, showTabs: store.isTabBarVisible)
    }
}

private struct WindowConnection: NSViewRepresentable {
    let store: ProjectStore
    func makeNSView(context: Context) -> WindowHook { WindowHook(store: store) }
    func updateNSView(_ view: WindowHook, context: Context) {}
}

private final class WindowHook: NSView, NSWindowDelegate {
    let store: ProjectStore
    private var cancellables = Set<AnyCancellable>()
    private let auxiliaryUndoManager = UndoManager()
    /// Distance from the window's top edge to the window controls, as AppKit lays them out.
    private var nativeControlCentre: CGFloat?
    private var appliedProjectState: Bool?
    private var exitingFullScreen = false
    private var observers: [NSObjectProtocol] = []
    /// The controls' frames as AppKit laid them out, captured before any alignment.
    private var standardControlFrames: [NSRect] = []
    private var isAligning = false
    private var systemFullScreenChrome = false

    init(store: ProjectStore) {
        self.store = store
        super.init(frame: .zero)
        store.$root
            .sink { [weak self] root in self?.applyProjectState(root != nil) }
            .store(in: &cancellables)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        // QuillTeX draws its own file tabs, so leave AppKit's tab groups alone.
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .aqua)
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.title = store.root.map { "QuillTeX — \($0.deletingPathExtension().lastPathComponent)" } ?? "QuillTeX"
        store.window = window
        AppDelegate.stores[ObjectIdentifier(window)] = WeakProject(store)
        // AppKit re-lays out the title bar for reasons of its own (tiling, focus,
        // screen changes). `didUpdate` fires after those passes, so the controls are
        // put back on the bar's centre line whatever moved them.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            self?.updateChrome()
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateChromeSoon()
        })
        if nativeControlCentre == nil { nativeControlCentre = controlCentreFromTop() }
        if standardControlFrames.isEmpty {
            standardControlFrames = controlTypes.compactMap { window.standardWindowButton($0)?.frame }
        }
        for type in controlTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            // AppKit can move the controls without a resize (title changes, full-screen
            // transitions). Watch their real frames instead of guessing when to redo it.
            button.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                guard let self, !self.isAligning else { return }
                self.updateChromeSoon()
            })
        }
        applyProjectState(store.root != nil)
        // Window-frame restoration and SwiftUI's own sizing land just after the window
        // appears, so the launcher size is re-applied once they have settled.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.nativeControlCentre == nil { self.nativeControlCentre = self.controlCentreFromTop() }
            self.applyProjectState(self.store.root != nil)
            if self.store.root == nil, let window = self.window {
                self.applyWindowSize(ChromeMetrics.welcomeWindowSize, to: window)
            }
        }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let textView = window.firstResponder as? SourceTextView { return textView.undoManager }
        if window.firstResponder is NSTextView { return auxiliaryUndoManager }
        return store.activeDocument?.undoManager ?? auxiliaryUndoManager
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { store.confirmClose(store.documents) }
    func windowWillClose(_ notification: Notification) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let window = notification.object as? NSWindow { AppDelegate.stores.removeValue(forKey: ObjectIdentifier(window)) }
    }
    func windowDidResize(_ notification: Notification) { updateChromeSoon() }
    func windowDidEndLiveResize(_ notification: Notification) { updateChromeSoon() }
    func windowDidMove(_ notification: Notification) { updateChromeSoon() }
    func windowDidChangeScreen(_ notification: Notification) { updateChromeSoon() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateChromeSoon() }
    func windowDidBecomeKey(_ notification: Notification) { updateChromeSoon() }
    func windowWillEnterFullScreen(_ notification: Notification) {
        // Full-screen chrome — including the hover reveal — belongs to AppKit. Hand the
        // controls back untouched *before* the transition, or the strip slides down
        // without them.
        systemFullScreenChrome = true
        restoreWindowControls()
    }
    func windowDidEnterFullScreen(_ notification: Notification) { updateChromeSoon() }
    func windowDidExitFullScreen(_ notification: Notification) {
        systemFullScreenChrome = false
        updateChromeSoon()
    }

    private var controlTypes: [NSWindow.ButtonType] { [.closeButton, .miniaturizeButton, .zoomButton] }

    private func restoreWindowControls() {
        guard let window else { return }
        for (index, type) in controlTypes.enumerated() {
            guard let button = window.standardWindowButton(type), standardControlFrames.indices.contains(index) else { continue }
            isAligning = true
            button.frame = standardControlFrames[index]
            isAligning = false
        }
    }

    /// Corrects now and again after AppKit's own layout pass, which runs after this
    /// delegate call and would otherwise undo the correction.
    private func updateChromeSoon() {
        updateChrome()
        // AppKit can re-lay the title bar out a moment later; a short burst covers it
        // without leaving a timer running. Each pass is a no-op once centred.
        for delay in [0.0, 0.15, 0.4, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.updateChrome() }
        }
    }

    // MARK: - Window modes

    private func applyProjectState(_ projectOpen: Bool) {
        guard let window else { return }
        if appliedProjectState != projectOpen {
            appliedProjectState = projectOpen
            if projectOpen { enterWorkspaceMode(window) } else { enterWelcomeMode(window) }
        }
        updateChrome()
    }

    /// The launcher window stays a completely ordinary window: close, minimise, zoom
    /// and resize all keep working. It simply opens at the launcher size rather than
    /// at whatever size the workspace was left at.
    private func enterWelcomeMode(_ window: NSWindow) {
        if window.styleMask.contains(.fullScreen), !exitingFullScreen {
            exitingFullScreen = true
            window.toggleFullScreen(nil)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exitingFullScreen = false
                self.appliedProjectState = nil
                self.applyProjectState(self.store.root != nil)
            }
            return
        }
        applyWindowSize(ChromeMetrics.welcomeWindowSize, to: window)
    }

    private func enterWorkspaceMode(_ window: NSWindow) {
        // SwiftUI sizes a new window to the content's minimum, so a project that is
        // already open at launch would start cramped. Open up to an editing size,
        // and check again once SwiftUI has finished its own sizing pass.
        growIfCramped(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.store.root != nil, let window = self.window else { return }
            self.growIfCramped(window)
        }
    }

    /// Only widens a window that is still sitting at the workspace minimum, so a size
    /// the user chose is never overridden.
    private func growIfCramped(_ window: NSWindow) {
        let size = window.frame.size
        guard size.width <= ChromeMetrics.workspaceMinimumSize.width + 1,
              size.height <= ChromeMetrics.workspaceMinimumSize.height + 40 else { return }
        applyWindowSize(ChromeMetrics.workspaceWindowSize, to: window)
    }

    /// Sets the size of a window that has not been positioned by the user yet and puts
    /// it in the middle of the screen. `NSWindow.center()` already accounts for the menu
    /// bar and the Dock, so the window is never placed under either.
    private func applyWindowSize(_ size: CGSize, to window: NSWindow) {
        window.setContentSize(size)
        centre(window)
        // SwiftUI finishes its own sizing pass just after this one; centring again once
        // it has settled keeps the window in the middle instead of anchored to its top.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
            if abs(window.frame.size.width - size.width) < 2, abs(window.frame.size.height - size.height) < 2 {
                self.centre(window)
            }
        }
    }

    /// Places the window in the middle of the screen's visible area, which already
    /// excludes the menu bar and the Dock. Done by hand rather than with
    /// `NSWindow.center()`, which leaves the window noticeably above centre here.
    private func centre(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                      y: visible.minY + (visible.height - frame.height) / 2))
    }

    // MARK: - Chrome alignment

    /// The top bar is taller than a standard title bar, so the window controls are
    /// re-centred on it (and returned to their native spot on the launcher).
    private func updateChrome() {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if store.isFullScreen != fullScreen { store.isFullScreen = fullScreen }
        // Never touch the controls while the system owns the full-screen title bar.
        guard !fullScreen, !systemFullScreenChrome else { return }
        let target: CGFloat
        if store.root == nil {
            // The launcher keeps AppKit's own position.
            target = nativeControlCentre ?? ChromeMetrics.topBarHeight / 2
        } else {
            // The controls draw their circles about a point above the centre of their
            // frames (measured from screenshots), so aim a little lower to land them on
            // the bar's centre line.
            target = ChromeMetrics.topBarHeight / 2 + ChromeMetrics.trafficLightOpticalOffset
        }
        centreWindowControls(fromTop: target)
    }

    /// Top edge of the window, in window coordinates. The content view is not a safe
    /// reference: during a transition it can still report its previous size, which
    /// used to place the controls a few points too high.
    private func contentTop() -> CGFloat? {
        window?.frame.height
    }

    private func controlCentreFromTop() -> CGFloat? {
        guard let window,
              let button = window.standardWindowButton(.closeButton), let container = button.superview else { return nil }
        // Window coordinates start at the bottom-left, so the distance from the top is
        // the content top minus the button's centre.
        guard let top = contentTop() else { return nil }
        return top - container.convert(button.frame, to: nil).midY
    }

    private func centreWindowControls(fromTop: CGFloat) {
        guard let window, let top = contentTop() else { return }
        isAligning = true
        defer { isAligning = false }
        for (index, type) in controlTypes.enumerated() {
            guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
            var frame = button.frame
            // Horizontal placement is absolute: this runs on every layout pass, so a
            // relative nudge would walk the controls across the window.
            if standardControlFrames.indices.contains(index) {
                frame.origin.x = standardControlFrames[index].origin.x + ChromeMetrics.controlsHorizontalOffset
            }
            // Measure the button's centre from the content top, not from the container's
            // own bounds, so the container's height never enters the calculation.
            let current = top - container.convert(frame, to: nil).midY
            let delta = fromTop - current
            if abs(delta) < 0.1 { continue }
            frame.origin.y += container.isFlipped ? delta : -delta
            button.frame = frame
        }
    }
}
