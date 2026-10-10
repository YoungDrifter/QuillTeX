import SwiftUI
import AppKit

@main
struct QuillTeXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() {
        // QuillTeX draws its own file tabs in the top bar, so AppKit's window tab bar
        // is meaningless here: this also removes "Show Tab Bar" / "Show All Tabs" from
        // the View menu, which do nothing for this window.
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = PluginManager.shared
        AppUpdater.shared.start()
    }
    var body: some Scene {
        WindowGroup(id: "workspace", for: URL.self) { url in
            WorkspaceView(openURL: url.wrappedValue)
        }
            .defaultSize(width: ChromeMetrics.welcomeWindowSize.width, height: ChromeMetrics.welcomeWindowSize.height)
            .windowStyle(.hiddenTitleBar)
            .commands { ProjectCommands() }
        Settings { SettingsView() }
            .defaultSize(width: SettingsStyle.windowSize.width, height: SettingsStyle.windowSize.height)
            .windowResizability(.contentMinSize)
    }
}

struct ProjectCommands: Commands {
    @ObservedObject private var updater = AppUpdater.shared
    @FocusedObject private var store: ProjectStore?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    private var editUndoManager: UndoManager? {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView { return textView.undoManager }
        return store?.activeDocument?.undoManager ?? undoManager
    }
    private func openProjectPanel() {
        if let store { store.openPanel() }
        else { AppDelegate.pendingOpenPanel = false; openWindow(id: "workspace") }
    }
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { editUndoManager?.undo() }
                .keyboardShortcut("z").disabled(editUndoManager?.canUndo != true)
            Button("Redo") { editUndoManager?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(editUndoManager?.canRedo != true)
        }
        CommandGroup(after: .appSettings) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Document…") {
                if let store { store.showTemplateChooser = true }
                else { AppDelegate.pendingNewDocument = true; openWindow(id: "workspace") }
            }.keyboardShortcut("n")
            Button("New Window") { openWindow(id: "workspace") }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Library & Recents…") { store?.showLibrary = true }.disabled(store == nil || store?.root == nil)
            Button("Open LaTeX File…") { openProjectPanel() }.keyboardShortcut("o")
            Divider()
            Button("Reveal Project in Finder") {
                if let directory = store?.directory { NSWorkspace.shared.open(directory) }
            }.disabled(store?.root == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { store?.saveActive() }.keyboardShortcut("s").disabled(store?.activeDocument == nil)
            Button("Save All") { store?.saveAllFromCommand() }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(store?.root == nil)
            Button("Close Current Subfile") {
                if let document = store?.activeDocument { store?.close(document) }
            }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(store?.activeDocument == nil || store?.activeDocument?.url == store?.root)
        }
        CommandMenu("Compile") {
            Button("Compile Main File") { store?.buildNow() }
                .keyboardShortcut("t")
                .disabled(store?.root == nil)
            Button("Compile Settings…") { store?.showBuildSettings = true }
            Divider()
            Button("Cancel Build") { store?.build.cancel() }.disabled(store?.build.status.isRunning != true)
        }
        CommandMenu("Navigate") {
            Button("Back") { store?.moveHistory(-1) }.keyboardShortcut("[", modifiers: [.command]).disabled(store?.canGoBack != true)
            Button("Forward") { store?.moveHistory(1) }.keyboardShortcut("]", modifiers: [.command]).disabled(store?.canGoForward != true)
            Button("Open File in Project…") { store?.showFilePicker = true }.keyboardShortcut("p").disabled(store?.root == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Show or Hide Sidebar") { store?.sidebarVisible.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
            Toggle("Show Tab Bar", isOn: Binding(get: { store?.isTabBarVisible ?? false }, set: { store?.setTabBarVisible($0) }))
                .disabled(store?.root == nil)
            Button("Editor Only") { store?.paneMode = .editor }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Editor and PDF") { store?.showEditorAndPDF() }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("PDF Only") { store?.paneMode = .preview }.keyboardShortcut("3", modifiers: [.command, .option])
        }
    }
}

@MainActor final class WeakProject {
    weak var value: ProjectStore?
    init(_ value: ProjectStore) { self.value = value }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var stores: [ObjectIdentifier: WeakProject] = [:]
    static var pendingOpenURLs: [URL] = []
    static var openWorkspace: ((URL) -> Void)?
    static var pendingOpenPanel: Bool?
    static var pendingNewDocument = false
    /// `--open <path>` on the command line. Claimed once, by the launch window, so a
    /// later "New Window" starts at the launcher instead of reopening the project.
    private static var launchDocument: String? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--open"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }()
    static func consumeLaunchDocument() -> URL? {
        guard let path = launchDocument else { return nil }
        launchDocument = nil
        return URL(fileURLWithPath: path)
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = PluginManager.shared
        AppUpdater.shared.start()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for item in Self.stores.values {
            if let store = item.value, !store.confirmClose(store.documents) { return .terminateCancel }
        }
        return .terminateNow
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        Self.openDocuments(urls)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Self.openDocuments(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    static func openDocuments(_ urls: [URL]) {
        for incoming in urls where incoming.isFileURL {
            let url = incoming.standardizedFileURL
            let stores = Self.stores.values.compactMap(\.value)
            let resolved = try? ProjectStore.resolveMainFile(url)
            if let existing = stores.first(where: { (resolved != nil && $0.root == resolved?.url) || $0.documents.contains(where: { $0.url == url }) }) {
                existing.openSource(url)
                existing.window?.makeKeyAndOrderFront(nil)
            } else if let welcome = stores.first(where: { $0.root == nil }) {
                welcome.openProject(url)
                welcome.window?.makeKeyAndOrderFront(nil)
            } else if let openWorkspace = Self.openWorkspace {
                openWorkspace(url)
            } else {
                Self.pendingOpenURLs.append(url)
            }
        }
    }
}

