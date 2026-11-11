import SwiftUI
import AppKit
import Combine

struct WorkspaceView: View {
    // The window's store must use the shared catalog so opening any local .tex
    // links it into the document library (All Documents / folders) immediately.
    @StateObject private var store = ProjectStore(catalog: DocumentCatalog.shared)
    @StateObject private var libraryDialogs = LibraryDialogCenter.shared
    @StateObject private var dialogCenter = QuillDialogCenter.shared
    @Environment(\.openWindow) private var openWindow
    var openURL: URL? = nil
    var body: some View {
        ZStack(alignment: .topLeading) {
            // The window is one shell: the sidebar (library page 1 / project page 2)
            // and the content card. With no document open the content card hosts the
            // All Docs browser, so there is no separate launch screen.
            WorkspaceSplit(store: store)
            if let message = store.recoveryMessage, store.root != nil {
                HStack(spacing: 8) {
                    Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.recoveryMessage = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("Dismiss recovery message").accessibilityLabel("Dismiss recovery message")
                }
                .padding(.horizontal, 14).frame(height: 32).background(.thinMaterial, in: Capsule())
                .padding(.top, ChromeMetrics.topBarHeight + ChromeMetrics.paneHeaderHeight + 4)
                .padding(.leading, store.sidebarVisible ? store.sidebarWidth + 16 : 16)
                .padding(.trailing, 16)
            }
        }
        .frame(minWidth: ChromeMetrics.workspaceMinimumSize.width, maxWidth: .infinity,
               minHeight: ChromeMetrics.workspaceMinimumSize.height, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
        .background(WindowConnection(store: store))
        .focusedSceneObject(store)
        .overlay {
            ZStack {
                if store.showNewDocument {
                    NewDocumentDialog(templates: store.library.templates,
                                      directory: LibraryPreferences.shared.newDocumentStartDirectory,
                                      onDismiss: {
                                          store.showNewDocument = false
                                          store.pendingNewDocumentFolder = nil
                                      }) { name, template, directory in
                        store.createNewDocument(named: name, template: template, in: directory)
                    }
                    .transition(.opacity)
                    .zIndex(20)
                }
                if let request = libraryDialogs.folderDialog {
                    NewFolderDialog(catalog: .shared,
                                    request: request,
                                    onDismiss: { libraryDialogs.folderDialog = nil })
                        .transition(.opacity)
                        .zIndex(21)
                }
                if let request = dialogCenter.alert {
                    QuillOverlayAlert(request: request, dismiss: { dialogCenter.alert = nil })
                        .transition(.opacity)
                        .zIndex(22)
                }
                if let request = dialogCenter.confirmRequest {
                    QuillOverlayConfirm(request: request, dismiss: { dialogCenter.confirmRequest = nil })
                        .transition(.opacity)
                        .zIndex(22)
                }
                if let request = dialogCenter.promptRequest {
                    QuillOverlayPrompt(request: request, dismiss: { dialogCenter.promptRequest = nil })
                        .transition(.opacity)
                        .zIndex(22)
                }
                if let request = dialogCenter.saveChanges {
                    QuillOverlaySaveChanges(request: request, dismiss: { dialogCenter.saveChanges = nil })
                        .transition(.opacity)
                        .zIndex(22)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.showNewDocument)
        .animation(.easeOut(duration: 0.18), value: libraryDialogs.folderDialog?.id)
        .animation(.easeOut(duration: 0.18), value: dialogCenter.alert?.id)
        .animation(.easeOut(duration: 0.18), value: dialogCenter.confirmRequest?.id)
        .animation(.easeOut(duration: 0.18), value: dialogCenter.promptRequest?.id)
        .animation(.easeOut(duration: 0.18), value: dialogCenter.saveChanges?.id)
        .onChange(of: store.root) { _, root in
            store.sidebarPage = root == nil ? .library : .structure
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkExternalChanges()
            store.library.reloadTemplates()
            store.catalog?.refreshMetadata()
        }
        .onChange(of: store.showingSettings) { _, showing in
            if showing {
                store.sidebarVisible = true
                store.sidebarPage = .structure
            }
        }
        .onChange(of: store.sidebarVisible) { _, _ in store.scheduleSessionSave() }
        .onChange(of: store.sidebarMode) { _, _ in store.scheduleSessionSave() }
        .onChange(of: store.paneMode) { _, _ in store.scheduleSessionSave() }
        .onChange(of: store.expandedNodes) { _, _ in store.scheduleSessionSave() }
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
                AppDelegate.pendingNewDocument = false; store.openNewDocumentSheet()
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
            if AppDelegate.pendingSettings {
                AppDelegate.pendingSettings = false
                store.openSettingsTab()
            }
            // A plain launch starts on the All Documents home page as a tab, not on an
            // empty tab strip with the New Tab button standing in for the page.
            if store.root == nil, store.tabs.isEmpty, !store.showingSettings {
                store.showLibraryPage()
            }

        }
    }
}

private struct EditorPane: View {
    @ObservedObject var store: ProjectStore
    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if store.showingSettings {
                    SettingsView(embedded: true)
                } else if store.root == nil || store.showingLibrary {
                    LibraryBrowser(store: store, catalog: .shared,
                                   onOpenEntry: { store.openLibraryEntry($0) },
                                   onNew: { store.openNewDocumentSheet() },
                                   onOpen: { store.openPanel() })
                } else if let document = store.activeDocument {
                    SourceEditor(document: document, store: store).id(document.id)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if store.root != nil && !store.showingLibrary && !store.showingSettings {
            HStack(spacing: 8) {
                Label(store.activeDocument?.isDirty == true ? "Unsaved" : "Saved",
                      systemImage: "square.and.pencil")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.primaryInk)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .quillFloatingCapsule()
                    .help(store.activeDocument?.isDirty == true ? "Unsaved changes" : "All changes saved")
                Spacer(minLength: 8)
                if let document = store.activeDocument { EditorHistoryButtons(document: document) }
            }.quillPaneRow()
            }
        }
        // The library, New Tab and Templates surfaces sit on the shared backdrop;
        // documents and the embedded Settings page get the white card.
        .background(store.root == nil || store.showingLibrary ? Color.clear : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "text.book.closed").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text("Start with a document").font(.system(size: 19, weight: .medium))
            Text("Open a .tex file to keep writing.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button { store.openPanel() } label: {
                Text("Open LaTeX File…").padding(.horizontal, 18).frame(height: 34).quillCapsule()
            }.buttonStyle(.plain).padding(.top, 4)
            Text("⌘O").font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.controlSurface)
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
        }.padding(2).quillFloatingCapsule()
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
                .frame(width: 26, height: 26).contentShape(Circle())
        }
        .buttonStyle(ChromeButtonStyle())
        .modifier(ChromeHoverFeedback()).disabled(!enabled)
        .help("\(title) (\(shortcut))").accessibilityLabel(title)
    }
}
private struct WorkspaceSplit: NSViewRepresentable {
    @ObservedObject var store: ProjectStore
    final class Coordinator {
        var root: URL?
        var controller: WorkspaceSplitController?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WorkspaceSplitContainer {
        let editorHost = NSHostingController(rootView: EditorPane(store: store))
        let previewHost = NSHostingController(rootView: PreviewPane(store: store))
        // Pane content fills the card; its SwiftUI fitting height must not stretch
        // the split's items beyond the window height.
        editorHost.sizingOptions = []
        previewHost.sizingOptions = []
        let controller = WorkspaceSplitController(sidebar: chromeHostingController(ProjectSidebar(store: store)),
                                 topBar: chromeHostingController(TopBar(store: store)),
                                 editor: editorHost,
                                 preview: previewHost,
                                 topBarHeight: ChromeMetrics.topBarHeight)
        controller.restoreLayout(sidebarWidth: store.sidebarWidth, editorFraction: store.editorFraction)
        context.coordinator.root = store.root
        context.coordinator.controller = controller
        controller.onLayoutChange = { [weak store] width, fraction in
            guard let store else { return }
            let snapped = abs(fraction - 0.5) < 0.01 ? 0.5 : fraction
            if abs(store.sidebarWidth - width) > 0.5 || abs(store.editorFraction - snapped) > 0.001 {
                store.sidebarWidth = width; store.editorFraction = snapped
                store.scheduleSessionSave()
            }
        }
        controller.onSidebarVisibilityChange = { [weak store] visible in
            guard let store, store.sidebarVisible != visible else { return }
            store.sidebarVisible = visible
        }
        let container = WorkspaceSplitContainer()
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = [.width, .height]
        controller.view.frame = container.bounds
        container.addSubview(controller.view)
        return container
    }
    /// The split controller reports a large fitting size from its panes' minimum
    /// widths; SwiftUI must fill the window instead of sizing the window around it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceSplitContainer, context: Context) -> CGSize? {
        let window = nsView.window?.contentView?.bounds.size
        return CGSize(width: proposal.width ?? window?.width ?? ChromeMetrics.workspaceWindowSize.width,
                      height: proposal.height ?? window?.height ?? ChromeMetrics.workspaceWindowSize.height)
    }
    func updateNSView(_ container: WorkspaceSplitContainer, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        if context.coordinator.root != store.root {
            context.coordinator.root = store.root
            controller.restoreLayout(sidebarWidth: store.sidebarWidth, editorFraction: store.editorFraction)
        }
        // Settings always sits on the inset white card, even with no document open.
        let showingLibrary = (store.root == nil || store.showingLibrary) && !store.showingSettings
        controller.setCardStyle(showingLibrary ? .library : .document)
        // Settings uses the window sidebar's second page for its categories, so
        // the sidebar stays visible.
        controller.update(sidebarVisible: store.sidebarVisible,
                          paneMode: showingLibrary || store.showingSettings ? .editor : store.paneMode,
                          splitLayoutVersion: store.splitLayoutVersion)
    }
}

/// A plain NSView host: unlike NSViewControllerRepresentable it has no fitting
/// size to hand SwiftUI, so the split always fills the window instead of the
/// window being sized around the controller's subview constraints.
private final class WorkspaceSplitContainer: NSView {
    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
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
    private weak var alignedTitlebar: NSView?
    private var originalTitlebarFrame: NSRect?
    private var adjustedTitlebarFrame: NSRect?
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
        window.isOpaque = false
        window.backgroundColor = .clear
        // A QuillTeX window is a single workspace rather than an AppKit tab group.
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
            if let window = self.window, window.frame.size.width <= ChromeMetrics.workspaceMinimumSize.width + 1 {
                self.applyWindowSize(ChromeMetrics.workspaceWindowSize, to: window)
            }
        }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let textView = window.firstResponder as? SourceTextView { return textView.undoManager }
        if window.firstResponder is NSTextView { return auxiliaryUndoManager }
        return store.activeDocument?.undoManager ?? auxiliaryUndoManager
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store.confirmClose(store.documents) else { return false }
        store.finishClosing()
        return true
    }
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
        if let titlebar = alignedTitlebar, let originalTitlebarFrame, titlebar.frame == adjustedTitlebarFrame {
            titlebar.frame = originalTitlebarFrame
            titlebar.updateTrackingAreas()
        }
        originalTitlebarFrame = nil; adjustedTitlebarFrame = nil
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
            // The library and the document workspace share one shell, so both open
            // at the same editing size. SwiftUI sizes a new window to the content's
            // minimum, so widen a cramped window once the project state settles.
            growIfCramped(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, let window = self.window else { return }
                self.growIfCramped(window)
            }
        }
        updateChrome()
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
        // The library and the workspace share the same 46 pt top strip. The controls
        // draw their circles about a point above the centre of their frames (measured
        // from screenshots), so aim a little lower to land them on the strip's line.
        let target = ChromeMetrics.topBarHeight / 2 + ChromeMetrics.trafficLightOpticalOffset
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
        guard let window, let top = contentTop(),
              let close = window.standardWindowButton(.closeButton),
              let buttonContainer = close.superview,
              let titlebar = buttonContainer.superview, let parent = titlebar.superview else { return }
        isAligning = true
        defer { isAligning = false }
        // Keep the widgets in AppKit's native local frames and move their titlebar
        // container together, so native hover/tiling tracking follows the same bounds.
        for (index, type) in controlTypes.enumerated() {
            guard let button = window.standardWindowButton(type), standardControlFrames.indices.contains(index),
                  button.frame != standardControlFrames[index] else { continue }
            button.frame = standardControlFrames[index]
        }
        let current = top - buttonContainer.convert(close.frame, to: nil).midY
        let delta = fromTop - current
        let horizontal = ChromeMetrics.controlsHorizontalOffset
        let currentX = buttonContainer.convert(close.frame, to: nil).minX
        let expectedX = (standardControlFrames.first?.minX ?? currentX) + horizontal
        guard abs(delta) >= 0.1 || abs(expectedX - currentX) >= 0.1 else { return }
        if titlebar.frame != adjustedTitlebarFrame {
            originalTitlebarFrame = titlebar.frame
        }
        alignedTitlebar = titlebar
        var frame = titlebar.frame
        frame.origin.y += parent.isFlipped ? delta : -delta
        frame.origin.x += expectedX - currentX
        titlebar.frame = frame
        adjustedTitlebarFrame = frame
        titlebar.updateTrackingAreas()
        buttonContainer.updateTrackingAreas()
        controlTypes.compactMap { window.standardWindowButton($0) }.forEach { $0.updateTrackingAreas() }
    }
}
