import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import PDFKit

@MainActor
final class SourceDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var text: String
    @Published var savedText: String
    var diskText: String
    var selection = NSRange(location: 0, length: 0)
    var scrollOrigin = NSPoint.zero
    var restoresEditorPosition = false
    var pendingHighlightedLine: Int?
    var hasMarkedText = false
    let undoManager = UndoManager()
    private var undoObservers: [NSObjectProtocol] = []
    var editorSurface: EditorSurface?
    var isDirty: Bool {
        let current = text as NSString, saved = savedText as NSString
        return current.length != saved.length || !current.isEqual(to: savedText)
    }
    init(url: URL, text: String) {
        self.url = url; self.text = text; self.savedText = text; self.diskText = text
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, Notification.Name.NSUndoManagerDidUndoChange,
                     Notification.Name.NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
    }
    deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case structure = "Structure", tex = "TeX", folder = "Folder", result = "Result"
    var id: String { rawValue }
    var icon: String {
        switch self { case .structure: "doc.text"; case .tex: "doc.on.doc"; case .folder: "folder"; case .result: "exclamationmark.triangle" }
    }
}
enum SidebarPage: String, CaseIterable, Identifiable {
    /// The document library page: New / Open plus All Docs, Starred, Folders and Tags.
    case library = "Library"
    /// The project navigation page currently shown by Structure / TeX / Folder / Result.
    case structure = "Structure"
    var id: String { rawValue }
}

enum PaneMode: Int, CaseIterable { case editor, split, preview }
struct EditorLocation: Equatable { var url: URL; var offset: Int }

/// One tab in the window. A tab with no path is the New Tab page; opening a
/// document from it turns that tab into the document tab.
struct WorkspaceTab: Identifiable, Equatable {
    let id: UUID
    var path: URL?
    var title: String
    var isSettings: Bool
    /// A library page tab (home / All Documents / Unsorted) — not a document itself.
    var isLibrary: Bool
    var selection: LibrarySelection?
    /// Editing a template file: a normal text editor, no preview and no compile.
    var isTemplate: Bool
    init(id: UUID = UUID(), path: URL?, title: String, isSettings: Bool = false,
         isLibrary: Bool = false, selection: LibrarySelection? = nil,
         isTemplate: Bool = false) {
        self.id = id
        self.path = path
        self.title = title
        self.isSettings = isSettings
        self.isLibrary = isLibrary
        self.selection = selection
        self.isTemplate = isTemplate
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    let library: DocumentLibrary
    /// The user's document library. The app injects the shared catalog; tests leave it
    /// nil so opening a project never writes to the user's library.
    var catalog: DocumentCatalog?
    /// Typesetting for this project. One controller per store, so one compiler per window.
    let build = BuildController()
    let sessionStore: WorkspaceSessionStore
    private var sessionTask: Task<Void, Never>?
    private var restoringSession = false
    private var sessionClosed = false
    private var retiredSessionRoots: Set<URL> = []
    private var buildObservers: [AnyCancellable] = []
    private let indexCache = ProjectIndexCache()
    private var indexWorker: Task<ProjectIndex, Never>?
    private var syncTask: Task<Void, Never>?
    private var editRevision = 0
    private var buildRevision = 0
    private(set) var previewIsOutdated = false
    private let maintainsRootDirectives: Bool
    private var maintainingRootDirectives = false
    private var pendingRootDirectives: Set<URL> = []
    var sourceDirectory: URL?
    /// The sidebar width is window chrome rather than document state: the last
    /// width the user dragged is kept as an app-wide preference so it survives
    /// relaunch, including on the All Documents page where no project is open.
    static let sidebarWidthDefaultsKey = "workspace.sidebarWidth"
    static let defaultSidebarWidth: Double = 248
    static func clampedSidebarWidth(_ width: Double) -> Double {
        width.isFinite ? min(400, max(180, width)) : defaultSidebarWidth
    }
    @Published var sidebarWidth: Double = defaultSidebarWidth
    @Published var editorFraction: Double = 0.5
    @Published var pdfReadingState: PDFReadingState?
    @Published var syncStatusMessage: String?
    @Published var recoveryMessage: String?
    private let defaults: UserDefaults
    init(library: DocumentLibrary? = nil, catalog: DocumentCatalog? = nil,
         maintainsRootDirectives: Bool = true, defaults: UserDefaults = .standard) {
        self.maintainsRootDirectives = maintainsRootDirectives
        self.catalog = catalog
        let library = library ?? .shared
        self.library = library
        self.defaults = defaults
        let savedWidth = defaults.object(forKey: Self.sidebarWidthDefaultsKey) as? Double
        sidebarWidth = Self.clampedSidebarWidth(savedWidth ?? Self.defaultSidebarWidth)
        sessionStore = WorkspaceSessionStore(directory: library.directory.appendingPathComponent("WorkspaceSessions"))
        build.$status.dropFirst().sink { [weak self] status in
            guard let self else { return }
            if status.isRunning { self.buildRevision = self.build.activeSourceRevision ?? self.editRevision }
            if case .succeeded = status { self.previewIsOutdated = self.buildRevision != self.editRevision }
            self.objectWillChange.send()
        }.store(in: &buildObservers)
        build.$diagnostics.sink { [weak self] diagnostics in
            guard let self else { return }
            for document in self.documents { document.editorSurface?.updateDiagnostics(diagnostics) }
        }.store(in: &buildObservers)
        build.$pdfVersion.dropFirst().sink { [weak self] _ in
            self?.syncTask?.cancel()
            self?.syncStatusMessage = nil
            self?.observedPDFData = self?.build.pdfURL.flatMap { try? Data(contentsOf: $0) }
            self?.updateFileMonitoring()
        }.store(in: &buildObservers)
        NotificationCenter.default.publisher(for: PluginManager.texProjectChanged).sink { [weak self] notification in
            guard let self else { return }
            if notification.object as? Bool == false {
                if self.sidebarMode == .tex { self.sidebarMode = .folder }
            }
            self.objectWillChange.send()
        }.store(in: &buildObservers)
        catalog?.$entries.dropFirst().sink { [weak self] entries in
            self?.updateProjectTitles(from: entries)
        }.store(in: &buildObservers)
        BuildSettings.shared.$outputDirectory.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFileMonitoring()
                self?.checkExternalChanges()
            }
        }.store(in: &buildObservers)
    }
    @Published var projectNamePrompt: QuillPromptRequest?

    /// The New Document dialog.
    @Published var showNewDocument = false
    /// Open tabs in this window; a nil path is the New Tab page.
    @Published var tabs: [WorkspaceTab] = []
    @Published var activeTabID: UUID? {
        didSet {
            guard oldValue != activeTabID else { return }
            synchronizeTabVisibility()
        }
    }
    /// The library surface is showing while the window's tabs stay open.
    @Published var showingLibrary = true
    /// The Settings tab is showing in the window content.
    @Published var showingSettings = false
    /// Which library view the browser is showing.
    @Published var librarySelection: LibrarySelection = .all
    /// Library folder the next New Document sheet should file the document into.
    @Published var pendingNewDocumentFolder: UUID?
    /// Template editing must not write root directives, catalog links or builds.
    private var openingTemplate = false
    private var paneModeBeforeTemplate: PaneMode?
    /// Display title of `librarySelection`, mirrored in the library top strip.
    @Published var libraryLocationTitle: String = "All Documents"
    /// Which of the two sliding sidebar pages is visible.
    @Published var sidebarPage: SidebarPage = .library
    @Published var root: URL? { didSet { updateFileMonitoring() } }
    @Published var documents: [SourceDocument] = [] { didSet { updateFileMonitoring() } }
    @Published var activeID: UUID?
    @Published var index = ProjectIndex()
    /// TeX Project is a native part of the editor now.
    var texProjectEnabled: Bool { true }
    @Published var sidebarMode: SidebarMode = .structure {
        didSet { if sidebarMode == .tex && !texProjectEnabled { sidebarMode = .folder } }
    }
    @Published var sidebarVisible = true
    @Published var paneMode: PaneMode = .split
    @Published private(set) var splitLayoutVersion = 0
    func showEditorAndPDF() {
        // The pane buttons are mode switches, not an "equalize" command. While the
        // split is already visible a click must leave the user's divider exactly
        // where it is; only entering the split from a single pane equalizes once.
        guard paneMode != .split else { return }
        paneMode = .split
        splitLayoutVersion += 1
    }
    /// Set by the window hook: full screen hides the window controls, so the top bar moves over.
    @Published var isFullScreen = false
    @Published var selectedNodes: [SidebarMode: String] = [:]
    /// Only explicitly opened branches expand; newly indexed branches start collapsed.
    @Published var expandedNodes: Set<String> = []
    @Published var selectedFolder: URL?
    struct SidebarNameEdit {
        enum Kind: Equatable { case file, folder, rename }
        let id = UUID()
        let kind: Kind
        let parent: URL
        let originalURL: URL?
        let defaultName: String
        var text: String
        var error: String?
        var isCreation: Bool { originalURL == nil }
        var placeholderID: String { "pending-name:" + id.uuidString }
    }
    @Published var sidebarNameEdit: SidebarNameEdit?
    private var committingSidebarName = false

    @Published var isIndexing = false
    /// macOS blocks reads in protected folders (Desktop, Documents, Downloads) unless
    /// the app holds a matching privacy grant. Ad-hoc builds lose it on every rebuild.
    @Published var needsFolderAccess = false
    @Published var showBuildSettings = false
    @Published var history: [EditorLocation] = []
    @Published var historyPosition = -1
    var activeDocument: SourceDocument? { documents.first { $0.id == activeID } }
    var directory: URL? { root?.deletingLastPathComponent() }
    var canGoBack: Bool { historyPosition > 0 }
    var canGoForward: Bool { historyPosition >= 0 && historyPosition < history.count - 1 }
    private var accessPromptedFor: URL?
    private var autoCompileTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var generation = 0
    private var checkingExternal = false
    private var externalCheckPending = false
    weak var window: NSWindow? { didSet { updateFileMonitoring() } }
    private let fileMonitor = ProjectFileMonitor()
    private var observedPDFData: Data?
    enum ExternalChangeChoice { case keepMine, useExternal }
    /// The same decision is used by live updates and the save preflight.
    var externalChangeDecision: ((SourceDocument) -> ExternalChangeChoice)?
    /// Tests replace the modal close confirmation so a headless run can tell a
    /// real close intent apart from an ordinary tab switch.
    var closeConfirmationHandler: (([SourceDocument]) -> Bool)?
    /// Tests capture modal errors instead of blocking the run with an alert.
    var errorAlertHandler: ((String, String) -> Void)?

    private func updateFileMonitoring() {
        guard window != nil, root != nil, !sessionClosed else { fileMonitor.stop(); return }
        var urls = Set(documents.map(\.url))
        if let pdf = expectedPDF { urls.insert(pdf) }
        if let pdf = build.pdfURL { urls.insert(pdf) }
        fileMonitor.watch(urls) { [weak self] in self?.checkExternalChanges() }
    }

    var previewStatusText: String? {
        guard build.pdfURL != nil else { return nil }
        if build.status.isRunning { return "Compiling · showing the previous PDF" }
        if case .failed = build.status { return "Build failed · showing the last available PDF" }
        if previewIsOutdated { return "PDF is awaiting compilation" }
        return nil
    }

    func updatePDFReadingState(_ state: PDFReadingState) {
        pdfReadingState = state
        scheduleSessionSave()
    }
    /// Store the width dragged in either the library page or a document. It is
    /// shared by every window and restored at launch before any project opens.
    func setSidebarWidth(_ width: Double) {
        let clamped = Self.clampedSidebarWidth(width)
        guard clamped != sidebarWidth else { return }
        sidebarWidth = clamped
        defaults.set(clamped, forKey: Self.sidebarWidthDefaultsKey)
    }

    func scheduleSessionSave() {
        guard !restoringSession, !sessionClosed, root != nil else { return }
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.persistSession()
        }
    }
    func persistSession(includeDrafts: Bool = true, force: Bool = false) {
        guard !restoringSession, let root else { return }
        sessionTask?.cancel()
        guard !includeDrafts || force || !documents.contains(where: { $0.hasMarkedText }) else { return }
        let previous = force && includeDrafts ? (sessionStore.load(root: root) ?? retiredSessionRoots.first.flatMap { sessionStore.load(root: $0) }) : nil
        let state = WorkspaceSession(rootPath: root.path, documents: documents.map { document in
            if includeDrafts, document.hasMarkedText, let saved = previous?.documents.first(where: { $0.path == document.url.path }) { return saved }
            let hasDraft = includeDrafts && document.isDirty && !document.hasMarkedText
            return WorkspaceSession.Document(path: document.url.path,
                selectionLocation: document.selection.location, selectionLength: document.selection.length,
                scrollX: document.scrollOrigin.x, scrollY: document.scrollOrigin.y,
                draft: hasDraft ? document.text : nil, savedText: hasDraft ? document.savedText : nil,
                diskText: hasDraft ? document.diskText : nil)
        }, activePath: activeDocument?.url.path, sidebarVisible: sidebarVisible, sidebarMode: sidebarMode.rawValue,
            paneMode: paneMode.rawValue, expandedNodes: Array(expandedNodes),
            sidebarWidth: sidebarWidth, pdf: pdfReadingState, pdfIsOutdated: previewIsOutdated,
            sourceDirectoryPath: sourceDirectory?.path)
        let retiring = Array(retiredSessionRoots.filter { $0 != root })
        sessionStore.save(state, retiringRoots: retiring) { [weak self] error in
            Task { @MainActor in
                if let error { self?.recoveryMessage = "Could not save recovery data: \(error)" }
                else { self?.retiredSessionRoots.subtract(retiring) }
            }
        }
    }
    func finishClosing() {
        sidebarNameEdit = nil
        persistSession(includeDrafts: false)
        sessionClosed = true
        sessionTask?.cancel()
        sessionStore.flush()
        indexTask?.cancel(); indexWorker?.cancel(); syncTask?.cancel(); autoCompileTask?.cancel()
        build.cancel()
        fileMonitor.stop()
    }
    private func restoreSession(_ state: WorkspaceSession?) {
        guard let state, state.rootPath == root?.path else { return }
        if let path = state.sourceDirectoryPath, let root {
            let base = URL(fileURLWithPath: path, isDirectory: true)
            if ProjectIndexer.isWithin(root, directory: base) { sourceDirectory = base }
        }
        var restored: [SourceDocument] = []
        for saved in state.documents {
            let url = URL(fileURLWithPath: saved.path).standardizedFileURL
            guard url.pathExtension.lowercased() == "tex", !restored.contains(where: { $0.url == url }) else { continue }
            let disk = try? String(contentsOf: url, encoding: .utf8)
            guard let text = saved.draft ?? disk else { continue }
            let document = documents.first(where: { $0.url == url }) ?? SourceDocument(url: url, text: text)
            document.text = text
            document.savedText = saved.draft == nil ? text : (saved.savedText ?? disk ?? "")
            document.diskText = saved.draft == nil ? (disk ?? text) : (saved.diskText ?? disk ?? "")
            let length = (text as NSString).length
            let location = min(max(0, saved.selectionLocation), length)
            document.selection = NSRange(location: location, length: min(max(0, saved.selectionLength), length - location))
            document.scrollOrigin = NSPoint(x: max(0, saved.scrollX), y: max(0, saved.scrollY))
            document.restoresEditorPosition = true
            restored.append(document)
        }
        if let main = documents.first(where: { $0.url == root }), !restored.contains(where: { $0.url == root }) { restored.insert(main, at: 0) }
        restored = restored.filter { $0.url == root } + restored.filter { $0.url != root }
        documents = restored
        activeID = restored.first(where: { $0.url.path == state.activePath })?.id ?? restored.first?.id
        sidebarVisible = state.sidebarVisible
        sidebarMode = state.sidebarMode == "Subfiles" ? .tex : (SidebarMode(rawValue: state.sidebarMode) ?? .structure)
        paneMode = PaneMode(rawValue: state.paneMode) ?? .split
        expandedNodes = Set(state.expandedNodes)
        // Sidebar width is an app-wide preference now. Adopt the width stored with
        // the session only while no app-wide value exists yet, so existing
        // projects keep their layout once after upgrading.
        if defaults.object(forKey: Self.sidebarWidthDefaultsKey) == nil {
            sidebarWidth = Self.clampedSidebarWidth(state.sidebarWidth)
        }
        // Every project opens with the editor and preview equal.
        editorFraction = 0.5
        pdfReadingState = state.pdf
        previewIsOutdated = state.pdfIsOutdated == true || restored.contains { $0.isDirty } || sourcesAreNewerThanPDF(restored.map(\.url))
        if restored.contains(where: { $0.isDirty }) { recoveryMessage = "Recovered unsaved edits. Save when you are ready." }
        window?.isDocumentEdited = restored.contains { $0.isDirty }
        refreshIndex(immediate: true)
    }

    func importTemplates() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.allowsMultipleSelection = true; panel.message = "Choose .tex files to add to your template library"; panel.prompt = "Add Templates"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do { try library.importTemplate(url) }
            catch { showError("Could Not Add Template", "\(url.lastPathComponent): \(error.localizedDescription)") }
        }
    }
    private var folderExpansionOrder: [URL] = []
    static func folderExpansionKey(_ url: URL) -> String { "Folder:folder:" + url.resolvingSymlinksInPath().standardizedFileURL.path }

    func isProjectRootFolder(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path == directory?.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func visibleExpandedFolder(_ url: URL) -> Bool {
        guard let directory, ProjectIndexer.isWithin(url, directory: directory),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        var ancestor = url.resolvingSymlinksInPath().standardizedFileURL
        while true {
            if isProjectRootFolder(ancestor) { return true }
            guard expandedNodes.contains(Self.folderExpansionKey(ancestor)) else { return false }
            ancestor = ancestor.deletingLastPathComponent()
        }
    }

    var creationDirectory: URL? {
        guard let directory else { return nil }
        guard sidebarMode == .folder else { return directory }
        if let selectedFolder, visibleExpandedFolder(selectedFolder) { return selectedFolder }
        if let recent = folderExpansionOrder.reversed().first(where: visibleExpandedFolder) { return recent }
        // Restored workspaces have expansion state but no click history yet.
        let prefix = "Folder:folder:"
        return expandedNodes.filter { $0.hasPrefix(prefix) }
            .map { URL(fileURLWithPath: String($0.dropFirst(prefix.count))) }
            .filter(visibleExpandedFolder)
            .sorted { first, second in
                if first.pathComponents.count != second.pathComponents.count { return first.pathComponents.count > second.pathComponents.count }
                return first.path < second.path
            }.first ?? directory
    }

    func toggleFolder(_ url: URL) {
        let url = url.standardizedFileURL
        let key = Self.folderExpansionKey(url)
        if isProjectRootFolder(url) {
            selectedFolder = url; selectedNodes[.folder] = "folder:" + url.path
            return
        }
        if expandedNodes.contains(key) { expandedNodes.remove(key) }
        else {
            expandedNodes.insert(key)
            folderExpansionOrder.removeAll { $0 == url }
            folderExpansionOrder.append(url)
        }
        selectedFolder = url
        selectedNodes[.folder] = "folder:" + url.path
        scheduleSessionSave()
    }

    private func revealCreationParent(_ parent: URL) {
        guard let directory else { return }
        var ancestor = parent.standardizedFileURL
        while ProjectIndexer.isWithin(ancestor, directory: directory) {
            expandedNodes.insert(Self.folderExpansionKey(ancestor))
            if ancestor.path == directory.standardizedFileURL.path { break }
            ancestor = ancestor.deletingLastPathComponent()
        }
        folderExpansionOrder.removeAll { $0 == parent }
        folderExpansionOrder.append(parent)
        selectedFolder = parent
    }

    private func defaultSidebarName(folder: Bool, in parent: URL) -> String {
        let stem = folder ? "New Folder" : "Untitled"
        let suffix = folder ? "" : ".tex"
        var name = stem + suffix
        var number = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path) {
            name = stem + " " + String(number) + suffix; number += 1
        }
        return name
    }

    func beginSidebarCreation(folder: Bool, in parent: URL? = nil) {
        guard commitSidebarNameEdit(), let parent = parent ?? creationDirectory,
              let directory, ProjectIndexer.isWithin(parent, directory: directory) else { return }
        revealCreationParent(parent)
        sidebarMode = .folder
        let name = defaultSidebarName(folder: folder, in: parent)
        sidebarNameEdit = SidebarNameEdit(kind: folder ? .folder : .file, parent: parent,
            originalURL: nil, defaultName: name, text: name)
        selectedNodes[.folder] = sidebarNameEdit?.placeholderID
    }

    func beginSidebarRename(_ url: URL) {
        guard commitSidebarNameEdit(), let directory, ProjectIndexer.isWithin(url, directory: directory),
              FileManager.default.fileExists(atPath: url.path) else { return }
        sidebarMode = .folder
        sidebarNameEdit = SidebarNameEdit(kind: .rename, parent: url.deletingLastPathComponent(),
            originalURL: url, defaultName: url.lastPathComponent, text: url.lastPathComponent)
        selectedNodes[.folder] = "file:" + url.path
    }

    func updateSidebarName(_ text: String, id: UUID) {
        guard sidebarNameEdit?.id == id else { return }
        sidebarNameEdit?.text = text; sidebarNameEdit?.error = nil
    }

    @discardableResult
    func commitSidebarNameEdit(id: UUID? = nil) -> Bool {
        guard !committingSidebarName else { return true }
        guard let edit = sidebarNameEdit, id == nil || id == edit.id else { return true }
        committingSidebarName = true
        defer { committingSidebarName = false }
        var name = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let extensionOnly = edit.kind != .folder && name == "." + (edit.defaultName as NSString).pathExtension
        if name.isEmpty || extensionOnly { name = edit.defaultName }
        do {
            if let original = edit.originalURL { _ = try renameProjectFile(original, to: name) }
            else {
                if name == edit.defaultName { name = defaultSidebarName(folder: edit.kind == .folder, in: edit.parent) }
                if edit.kind == .folder { _ = try createFolder(named: name, in: edit.parent) }
                else { _ = try createTeXFile(named: name, in: edit.parent) }
            }
            if sidebarNameEdit?.id == edit.id { sidebarNameEdit = nil }
            return true
        } catch {
            if sidebarNameEdit?.id == edit.id { sidebarNameEdit?.error = error.localizedDescription }
            return false
        }
    }

    func cancelSidebarNameEdit(id: UUID) {
        guard sidebarNameEdit?.id == id else { return }
        sidebarNameEdit = nil
    }

    func sidebarChildren(of node: NavigationNode) -> [NavigationNode] {
        guard node.kind == .folder, let edit = sidebarNameEdit, edit.isCreation,
              node.url?.resolvingSymlinksInPath().path == edit.parent.resolvingSymlinksInPath().path else { return node.children }
        let url = edit.parent.appendingPathComponent(edit.defaultName, isDirectory: edit.kind == .folder)
        return node.children + [NavigationNode(id: edit.placeholderID, title: edit.defaultName,
            kind: edit.kind == .folder ? .folder : .source, url: url)]
    }

    func sidebarIsNaming(_ node: NavigationNode) -> Bool {
        guard let edit = sidebarNameEdit else { return false }
        return edit.isCreation ? node.id == edit.placeholderID : node.url == edit.originalURL
    }

    @discardableResult
    func createTeXFile(named proposedName: String, in parent: URL) throws -> URL {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw ProjectError.message("Enter a file name without path separators.")
        }
        let filename = name.lowercased().hasSuffix(".tex") ? name : name + ".tex"
        let url = parent.appendingPathComponent(filename).standardizedFileURL
        try createSubfile(at: url)
        revealCreationParent(parent)
        selectedNodes[.folder] = "file:" + url.path
        scheduleSessionSave()
        return url
    }

    @discardableResult
    func createFolder(named name: String, in parent: URL) throws -> URL {
        guard let directory, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0"), ProjectIndexer.isWithin(parent, directory: directory) else {
            throw ProjectError.message("Choose a folder name and location inside the current project.")
        }
        let target = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw ProjectError.message("A file or folder with this name already exists.")
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        indexCache.invalidateInventory()
        revealCreationParent(parent)
        selectedNodes[.folder] = "folder:" + target.path
        refreshIndex(immediate: true)
        scheduleSessionSave()
        return target
    }

    /// Create and link a new child; leave the main document's edits unsaved and
    /// use its native editor so inserting the reference can be undone normally.
    func createSubfile(at url: URL) throws {
        guard let root, let directory, let main = documents.first(where: { $0.url == root }) else {
            throw ProjectError.message("Open a project before creating a subfile.")
        }
        let url = url.standardizedFileURL
        guard url.pathExtension.lowercased() == "tex", ProjectIndexer.isWithin(url, directory: directory) else {
            throw ProjectError.message("Choose a .tex file inside the current project folder.")
        }
        guard !main.hasMarkedText else {
            throw ProjectError.message("Finish the current input method composition before creating a subfile.")
        }
        let inputPath = Self.relativeFilePath(to: url, from: directory)
        guard inputPath.rangeOfCharacter(from: CharacterSet(charactersIn: "%#{}\\\r\n")) == nil else {
            throw ProjectError.message("Choose a file and folder name without %, #, braces, backslashes or line breaks so LaTeX can include it.")
        }
        let newline = main.text.contains("\r\n") ? "\r\n" : "\n"
        let rootPath = Self.relativeFilePath(to: root, from: url.deletingLastPathComponent())
        let source = "% !TeX root = \(rootPath)" + newline + newline
        try Data(source.utf8).write(to: url, options: .withoutOverwriting)
        indexCache.invalidateInventory()
        let offset = ProjectIndexer.matches(#"\\end\s*\{document\}"#, in: ProjectIndexer.masked(main.text)).last?.range.location
            ?? (main.text as NSString).length
        let ns = main.text as NSString
        let prefix = offset > 0 && ns.substring(with: NSRange(location: offset - 1, length: 1)) != "\n" ? newline : ""
        let insertion = prefix + "\\input{\(inputPath)}" + newline
        if let surface = main.editorSurface {
            surface.textView.undoManager?.beginUndoGrouping()
            surface.textView.breakUndoCoalescing()
            surface.textView.insertText(insertion, replacementRange: NSRange(location: offset, length: 0))
            surface.textView.breakUndoCoalescing()
            surface.textView.undoManager?.setActionName("Add Subfile")
            surface.textView.undoManager?.endUndoGrouping()
        } else {
            main.text = ns.replacingCharacters(in: NSRange(location: offset, length: 0), with: insertion)
            edited(main)
        }
        openSource(url, offset: (source as NSString).length)
        refreshIndex(immediate: true)
    }

    /// Only project sources participate; hidden/build folders, application data
    /// and symlinks leaving the project are never edited by metadata maintenance.
    private var projectTeXFiles: [URL] {
        guard let directory = sourceDirectory ?? directory, let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return documents.map(\.url) }
        var files = Set(documents.map(\.url).filter { ProjectIndexer.isWithin($0, directory: directory) })
        for case let url as URL in enumerator {
            if url.lastPathComponent == "build" || url.standardizedFileURL == library.directory.standardizedFileURL
                || !ProjectIndexer.isWithin(url, directory: directory) {
                enumerator.skipDescendants(); continue
            }
            if url.pathExtension.lowercased() == "tex", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                files.insert(url.standardizedFileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    static func updatingRootDirective(in text: String, to path: String, replacingExisting: Bool) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let directive = "% !TeX root = " + path
        let literal = LaTeXHighlighter.spans(in: text).filter { $0.token == .verbatim }
        let matches = ProjectIndexer.matches(#"(?im)^(?:\x{FEFF})?[\t ]*(%[\t ]*![\t ]*tex[\t ]+root[\t ]*=[^\r\n]*)"#, in: text)
            .filter { match in !literal.contains { NSIntersectionRange($0.range, match.range).length > 0 } }
        if !matches.isEmpty {
            guard replacingExisting else { return text }
            let result = NSMutableString(string: text)
            for match in matches.reversed() { result.replaceCharacters(in: match.range(at: 1), with: directive) }
            return result as String
        }
        // Keep a UTF-8 BOM at the start of the file, before the new first line.
        if text.hasPrefix("\u{FEFF}") { return "\u{FEFF}" + directive + newline + text.dropFirst() }
        return directive + newline + text
    }

    func maintainProjectRootDirectives(replacingExisting: Bool, additionalFiles: [URL] = []) {
        guard maintainsRootDirectives, texProjectEnabled, !maintainingRootDirectives, let root else { return }
        maintainingRootDirectives = true
        defer { maintainingRootDirectives = false }
        var failed: [String] = []
        for url in Set(projectTeXFiles + additionalFiles).sorted(by: { $0.path < $1.path }) {
            let document = documents.first { $0.url == url }
            if document?.hasMarkedText == true { pendingRootDirectives.insert(url); continue }
            pendingRootDirectives.remove(url)
            do {
                var disk = try String(contentsOf: url, encoding: .utf8)
                if let document, disk != document.diskText {
                    guard reconcile(document, with: disk) else { continue }
                    disk = try String(contentsOf: url, encoding: .utf8)
                }
                let path = Self.relativeFilePath(to: root, from: url.deletingLastPathComponent())
                let updated = Self.updatingRootDirective(in: disk, to: path, replacingExisting: replacingExisting)
                if updated != disk {
                    guard try String(contentsOf: url, encoding: .utf8) == disk else {
                        failed.append(url.lastPathComponent); continue
                    }
                    try updated.write(to: url, atomically: true, encoding: .utf8)
                }
                if let document {
                    let buffer = Self.updatingRootDirective(in: document.text, to: path, replacingExisting: replacingExisting)
                    document.savedText = updated; document.diskText = updated
                    applyMetadataText(buffer, to: document)
                }
            } catch { failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty { recoveryMessage = "Could not update main-file comments: " + failed.joined(separator: ", ") }
        indexCache.invalidateInventory()
        refreshIndex(immediate: true); scheduleSessionSave()
        objectWillChange.send(); window?.isDocumentEdited = documents.contains { $0.isDirty }
    }

    /// Register one minimal native edit, preserving existing undo and unsaved body
    /// text rather than reloading a dirty buffer wholesale.
    func applyMetadataText(_ text: String, to doc: SourceDocument, actionName: String = "Update Main File Comment") {
        guard text != doc.text else { return }
        let before = doc.text as NSString, after = text as NSString
        var prefix = 0, suffix = 0
        while prefix < min(before.length, after.length), before.character(at: prefix) == after.character(at: prefix) { prefix += 1 }
        if prefix > 0, prefix < before.length, (0xDC00...0xDFFF).contains(before.character(at: prefix)) { prefix -= 1 }
        while suffix < min(before.length, after.length) - prefix,
              before.character(at: before.length - suffix - 1) == after.character(at: after.length - suffix - 1) { suffix += 1 }
        if suffix > 0, (0xDC00...0xDFFF).contains(before.character(at: before.length - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: before.length - prefix - suffix)
        let replacement = after.substring(with: NSRange(location: prefix, length: after.length - prefix - suffix))
        let oldSelection = doc.selection
        let delta = replacement.utf16.count - range.length
        let location = oldSelection.location >= NSMaxRange(range) ? oldSelection.location + delta : min(oldSelection.location, prefix)
        let selection = NSRange(location: max(0, location), length: min(oldSelection.length, max(0, after.length - location)))
        if let surface = doc.editorSurface {
            let scroll = surface.contentView.bounds.origin
            doc.undoManager.beginUndoGrouping()
            surface.textView.breakUndoCoalescing()
            surface.textView.insertText(replacement, replacementRange: range)
            surface.textView.breakUndoCoalescing()
            doc.undoManager.setActionName(actionName)
            doc.undoManager.endUndoGrouping()
            surface.textView.setSelectedRange(selection)
            surface.contentView.scroll(to: scroll); surface.reflectScrolledClipView(surface.contentView)
        } else { doc.text = text; doc.selection = selection }
    }

    static func relativeFilePath(to url: URL, from directory: URL) -> String {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] { common += 1 }
        return (Array(repeating: "..", count: base.count - common) + target.dropFirst(common)).joined(separator: "/")
    }

    func relativePath(_ url: URL) -> String {
        guard let directory else { return url.lastPathComponent }
        let prefix = directory.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }
    func showError(_ title: String, _ message: String) {
        if let errorAlertHandler { errorAlertHandler(title, message); return }
        QuillDialogCenter.shared.showAlert(title, message)
    }
    // MARK: - Document library

    /// Open a document chosen in the library. The sidebar flips to the project page
    /// only once the document actually became the workspace root.
    func openLibraryEntry(_ entry: LibraryEntry) {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            showError("Document Not Found", "“\(entry.displayName)” is no longer at \(entry.path).\nIt stays in the library until you remove it.")
            return
        }
        requestOpenProject(entry.url, explicitRoot: true)
    }

    // MARK: - Tabs and the library surface

    /// Show the library (All Documents / New Tab) while keeping the open tabs alive.
    func showLibraryPage() {
        showLibrary(selection: .all, title: "All Documents")
    }

    /// Show any library surface (All Documents, Starred, Templates, a folder) as the
    /// active tab. All Documents is the ephemeral home tab; each other section keeps
    /// its own tab so opening New Tab or a document does not discard it.
    func showLibrary(selection: LibrarySelection, title: String) {
        showingSettings = false
        sidebarPage = .library
        if let existing = tabs.first(where: { $0.isLibrary && $0.selection == selection }) {
            activateTab(existing)
        } else if selection == .all {
            if let index = activeTabID.flatMap({ id in tabs.firstIndex { $0.id == id } }),
               tabs[index].path == nil, !tabs[index].isSettings, !tabs[index].isLibrary {
                tabs[index].isLibrary = true
                tabs[index].selection = .all
                tabs[index].title = title
                activateTab(tabs[index])
            } else {
                let tab = WorkspaceTab(path: nil, title: title, isLibrary: true, selection: .all)
                tabs.insert(tab, at: 0)
                activateTab(tab)
            }
        } else {
            if let index = activeTabID.flatMap({ id in tabs.firstIndex { $0.id == id } }),
               tabs[index].path == nil, !tabs[index].isSettings, !tabs[index].isLibrary {
                // The New Tab page becomes this section's tab.
                tabs[index].isLibrary = true
                tabs[index].selection = selection
                tabs[index].title = title
                activateTab(tabs[index])
            } else {
                // Leaving All Documents: the home tab folds back into the home button.
                if let index = activeTabID.flatMap({ id in tabs.firstIndex { $0.id == id } }),
                   tabs[index].isLibrary, tabs[index].selection == .all {
                    tabs.remove(at: index)
                    activeTabID = nil
                }
                let tab = WorkspaceTab(path: nil, title: title, isLibrary: true, selection: selection)
                tabs.append(tab)
                activateTab(tab)
            }
        }
        showingLibrary = true
        librarySelection = selection
        libraryLocationTitle = title
    }

    /// Mirror the library sidebar selection into the active library tab.
    /// Open the New Tab page as a tab. Opening or creating a document from it
    /// turns this tab into the document tab instead of adding a second one.
    func showNewTabPage() {
        discardHomeTab()
        if let existing = tabs.first(where: { $0.path == nil && !$0.isSettings && !$0.isLibrary }) {
            activateTab(existing)
        } else {
            let tab = WorkspaceTab(path: nil, title: "New Tab")
            tabs.append(tab)
            activateTab(tab)
        }
        librarySelection = .newTab
        libraryLocationTitle = "New Tab"
        sidebarPage = .library
    }

    /// A New Tab page is ephemeral: leaving it without creating or opening a
    /// document removes the tab, so the "+ New Tab" control comes back.
    private func discardUnusedNewTab() {
        guard let id = activeTabID,
              let tab = tabs.first(where: { $0.id == id }),
              tab.path == nil, !tab.isSettings, !tab.isLibrary else { return }
        tabs.removeAll { $0.id == tab.id }
        activeTabID = tabs.last?.id
    }

    /// Only All Documents is the ephemeral "home" tab. Starred, Templates and folder
    /// tabs are ordinary tabs and stay open when another tab is opened.
    private func discardHomeTab() {
        guard tabs.contains(where: { $0.isLibrary && $0.selection == .all }) else { return }
        tabs.removeAll { $0.isLibrary && $0.selection == .all }
        if activeTabID == nil || !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.last?.id
        }
    }

    /// Open Settings as a tab instead of a separate window.
    func openSettingsTab() {
        discardHomeTab()
        if let existing = tabs.first(where: \.isSettings) {
            activateTab(existing)
            return
        }
        let tab = WorkspaceTab(path: nil, title: "Settings", isSettings: true)
        if let index = activeTabID.flatMap({ id in tabs.firstIndex { $0.id == id } }),
           tabs[index].path == nil, !tabs[index].isSettings, !tabs[index].isLibrary {
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        activateTab(tab)
    }

    // MARK: - Tab activation and closing

    /// The active tab is the single source of truth for which surface is shown;
    /// no code path may leave a document tab active while the library is drawn.
    private func synchronizeTabVisibility() {
        guard let id = activeTabID, let tab = tabs.first(where: { $0.id == id }) else {
            showingLibrary = true
            showingSettings = false
            return
        }
        if tab.isSettings {
            showingSettings = true
            showingLibrary = false
        } else if tab.isLibrary {
            showingSettings = false
            showingLibrary = true
            if let selection = tab.selection {
                librarySelection = selection
                libraryLocationTitle = tab.title
            }
        } else if tab.path == nil {
            showingSettings = false
            showingLibrary = true
            librarySelection = .newTab
            libraryLocationTitle = "New Tab"
        } else {
            showingSettings = false
            showingLibrary = false
        }
    }

    func projectTitle(for path: URL) -> String {
        if !openingTemplate, let entry = catalog?.entry(forMainFile: path) {
            return entry.displayName
        }
        return path.deletingPathExtension().lastPathComponent
    }

    private func updateProjectTitles(from entries: [LibraryEntry]) {
        for index in tabs.indices where !tabs[index].isTemplate {
            guard let path = tabs[index].path?.standardizedFileURL.path,
                  let name = entries.first(where: { $0.path == path })?.displayName,
                  tabs[index].title != name else { continue }
            tabs[index].title = name
        }
        if !isEditingTemplate, let path = root?.standardizedFileURL.path,
           let name = entries.first(where: { $0.path == path })?.displayName {
            window?.title = "QuillTeX — \(name)"
        }
    }

    func requestRenameProject(_ main: URL) {
        guard let catalog else { return }
        projectNamePrompt = QuillPromptRequest(
            title: "Rename Project",
            message: main.deletingLastPathComponent().path,
            initial: projectTitle(for: main),
            placeholder: "Project Name",
            confirmTitle: "Rename"
        ) { [weak self] name in
            guard let name else { return }
            do {
                if let entry = catalog.entry(forMainFile: main) {
                    try catalog.rename(entry.id, to: name)
                } else {
                    try catalog.link(main, displayName: name)
                }
            } catch {
                self?.showError("Could Not Rename Project", error.localizedDescription)
            }
        }
    }

    /// Convert the active New Tab / library tab into a document tab, or add one.
    private func registerDocumentTab(for main: URL) {
        let title = projectTitle(for: main)
        let normalized = main.standardizedFileURL
        let matches = tabs.indices.filter { index in
            tabs[index].path?.standardizedFileURL == normalized
        }
        if let keepIndex = matches.first {
            // Reuse the existing tab and collapse duplicate document tabs for the
            // same file, so opening a document repeatedly never stacks copies.
            let keepID = tabs[keepIndex].id
            let duplicateIDs = Set(matches.dropFirst().map { tabs[$0].id })
            if !duplicateIDs.isEmpty {
                tabs.removeAll { duplicateIDs.contains($0.id) }
            }
            discardHomeTab()
            if let active = activeTabID,
               let index = tabs.firstIndex(where: { $0.id == active }),
               tabs[index].path == nil, !tabs[index].isSettings, !tabs[index].isLibrary {
                tabs.remove(at: index)
            }
            if let index = tabs.firstIndex(where: { $0.id == keepID }) {
                tabs[index].title = title
            }
            activeTabID = keepID
            showingLibrary = false
            showingSettings = false
            sidebarPage = .structure
            return
        }
        if let index = activeTabID.flatMap({ id in tabs.firstIndex { $0.id == id } }),
           tabs[index].path == nil, !tabs[index].isSettings, !tabs[index].isLibrary {
            // A New Tab page turns into the document tab in place (it is the last
            // tab). Library home/section tabs keep their position and the document
            // is appended, so the strip reflects the order documents were opened.
            tabs[index].path = main
            tabs[index].title = title
            tabs[index].selection = nil
            activeTabID = tabs[index].id
        } else {
            discardHomeTab()
            let tab = WorkspaceTab(path: main, title: title)
            tabs.append(tab)
            activeTabID = tab.id
        }
        showingLibrary = false
        showingSettings = false
        sidebarPage = .structure
    }

    /// Persist the current tab's draft before another tab or project takes over.
    /// Editors and build state are recreated when the user comes back.
    func prepareToLeaveCurrentTab() {
        guard root != nil else { return }
        persistSession(includeDrafts: true)
    }

    /// The tab surface a failed activation returns to. Opening a document replaces
    /// the buffers, so a failed open must not leave the window on a tab whose
    /// document never loaded.
    private struct TabActivationSnapshot {
        var tabs: [WorkspaceTab]
        var activeTabID: UUID?
        var showingLibrary: Bool
        var showingSettings: Bool
        var sidebarPage: SidebarPage
        var librarySelection: LibrarySelection
        var libraryLocationTitle: String
        var paneMode: PaneMode
        var paneModeBeforeTemplate: PaneMode?
    }

    private func tabActivationSnapshot() -> TabActivationSnapshot {
        TabActivationSnapshot(tabs: tabs, activeTabID: activeTabID, showingLibrary: showingLibrary,
            showingSettings: showingSettings, sidebarPage: sidebarPage, librarySelection: librarySelection,
            libraryLocationTitle: libraryLocationTitle, paneMode: paneMode,
            paneModeBeforeTemplate: paneModeBeforeTemplate)
    }

    private func restoreTabActivation(_ snapshot: TabActivationSnapshot, keepingTabs: Bool = false) {
        if !keepingTabs { tabs = snapshot.tabs }
        activeTabID = snapshot.activeTabID
        showingLibrary = snapshot.showingLibrary
        showingSettings = snapshot.showingSettings
        sidebarPage = snapshot.sidebarPage
        librarySelection = snapshot.librarySelection
        libraryLocationTitle = snapshot.libraryLocationTitle
        paneMode = snapshot.paneMode
        paneModeBeforeTemplate = snapshot.paneModeBeforeTemplate
    }

    func activateTab(_ tab: WorkspaceTab) {
        let snapshot = tabActivationSnapshot()
        if tab.id != activeTabID {
            if isEditingTemplate { paneMode = paneModeBeforeTemplate ?? .split }
        }
        let wasEditingTemplate = isEditingTemplate
        if tab.id != activeTabID {
            discardUnusedNewTab()
            // Home is only the All Documents tab itself. Switching to any other tab
            // (including Templates/Starred/folders) folds it back into the home icon.
            if !(tab.isLibrary && tab.selection == .all) {
                discardHomeTab()
            }
        }
        activeTabID = tab.id
        if tab.isSettings {
            showingSettings = true
            showingLibrary = false
            sidebarPage = .structure
            return
        }
        showingSettings = false
        if tab.isLibrary {
            showingLibrary = true
            sidebarPage = .library
            if let selection = tab.selection {
                librarySelection = selection
                libraryLocationTitle = tab.title
            }
            return
        }
        guard let path = tab.path else {
            showingLibrary = true
            sidebarPage = .library
            librarySelection = .newTab
            libraryLocationTitle = "New Tab"
            return
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
            showError("Document Not Found", "“\(tab.title)” is no longer at \(path.path).")
            let removedIndex = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
            tabs.removeAll { $0.id == tab.id }
            if tab.id != snapshot.activeTabID {
                restoreTabActivation(snapshot, keepingTabs: true)
            } else if tabs.isEmpty {
                activeTabID = nil
                showNewTabPage()
            } else {
                activateTab(tabs[min(removedIndex, tabs.count - 1)])
            }
            return
        }
        // A template tab is a real editor page, never a project: activating it keeps
        // the template path so no root comment, recent entry or catalog link is written.
        if tab.isTemplate, !wasEditingTemplate { paneModeBeforeTemplate = paneMode }
        showingLibrary = false
        showingSettings = false
        sidebarPage = tab.isTemplate ? .library : .structure
        if root?.standardizedFileURL == path.standardizedFileURL {
            if tab.isTemplate { paneMode = .editor }
            if let doc = documents.first(where: { $0.url.standardizedFileURL == path.standardizedFileURL }) {
                openSource(doc.url)
            }
            return
        }
        guard switchToTab(path, asTemplate: tab.isTemplate) else {
            restoreTabActivation(snapshot)
            return
        }
        if tab.isTemplate {
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
                tabs[index].isTemplate = true
                tabs[index].title = tab.title
            }
            paneMode = .editor
            showingLibrary = false
            showingSettings = false
            sidebarPage = .library
        }
    }

    @discardableResult
    private func switchToTab(_ path: URL, asTemplate: Bool = false) -> Bool {
        prepareToLeaveCurrentTab()
        // Same project: reuse the open buffer instead of rebuilding the project.
        if let root, root.deletingLastPathComponent().standardizedFileURL == path.deletingLastPathComponent().standardizedFileURL,
           documents.contains(where: { $0.url.standardizedFileURL == path.standardizedFileURL }) {
            openSource(path)
            return true
        }
        return openProject(path, explicitRoot: true, asTemplate: asTemplate)
    }

    /// Reorder a non-home tab among the scrollable tabs. All Documents is pinned
    /// and cannot be dragged or displaced.
    func moveTab(_ id: UUID, by delta: Int) {
        guard delta != 0,
              let index = tabs.firstIndex(where: { $0.id == id }),
              !(tabs[index].isLibrary && tabs[index].selection == .all) else { return }
        let homeTabs = tabs.filter { $0.isLibrary && $0.selection == .all }
        var others = tabs.filter { !($0.isLibrary && $0.selection == .all) }
        guard let current = others.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, current + delta), others.count - 1)
        guard target != current else { return }
        let tab = others.remove(at: current)
        others.insert(tab, at: target)
        tabs = homeTabs + others
    }

    func closeTab(_ tab: WorkspaceTab) {
        let path = tab.path
        if let path, let document = documents.first(where: { $0.url.standardizedFileURL == path.standardizedFileURL }),
           document.isDirty {
            // Explicit tab close keeps the synchronous seam for tests, while the
            // app uses the non-blocking overlay so the button never freezes.
            if closeConfirmationHandler != nil {
                guard confirmClose([document]) else { return }
                finishCloseTab(tab)
                return
            }
            QuillDialogCenter.shared.showSaveChanges(title: "Save Changes Before Closing?",
                                                     detail: document.url.lastPathComponent) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .save:
                    guard self.save(document) else { return }
                    self.finishCloseTab(tab)
                case .discard:
                    self.finishCloseTab(tab)
                case .cancel:
                    break
                }
            }
            return
        }
        finishCloseTab(tab)
    }

    private func finishCloseTab(_ tab: WorkspaceTab) {
        let wasActive = activeTabID == tab.id
        let removedIndex = tabs.firstIndex(where: { $0.id == tab.id }) ?? tabs.count - 1
        tabs.removeAll { $0.id == tab.id }
        guard wasActive else { return }
        if tabs.isEmpty {
            activeTabID = nil
            // Closing the last tab (for example the All Documents home tab) lands on a
            // fresh New Tab page instead of an empty strip over the library.
            showNewTabPage()
            return
        }
        let next = tabs[min(max(removedIndex, 0), tabs.count - 1)]
        activateTab(next)
    }

    /// Turn the final tab back into the library home, keeping the open project
    /// buffers alive in case the user returns to them.
    func closeDocumentToLibrary() {
        prepareToLeaveCurrentTab()
        showingLibrary = true
        showingSettings = false
        sidebarPage = .library
        librarySelection = .all
        libraryLocationTitle = "All Documents"
    }

    var isEditingTemplate: Bool {
        guard let id = activeTabID else { return false }
        return tabs.first(where: { $0.id == id })?.isTemplate == true
    }

    /// Open a template as a direct editor page: no PDF preview, no compile
    /// controls, and no library/build side effects for the template file.
    func openTemplate(_ template: DocumentTemplate) {
        let wasEditingTemplate = isEditingTemplate
        let keepActive = activeTabID
        let previousSidebarPage = sidebarPage
        if !wasEditingTemplate { paneModeBeforeTemplate = paneMode }
        activeTabID = nil
        guard openProject(template.url, explicitRoot: true, asTemplate: true),
              root?.standardizedFileURL == template.url.standardizedFileURL else {
            activeTabID = keepActive
            sidebarPage = previousSidebarPage
            return
        }
        if let id = activeTabID, let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].isTemplate = true
            tabs[index].title = template.displayTitle
        }
        paneMode = .editor
        showingLibrary = false
        showingSettings = false
        sidebarPage = .library
    }

    var currentLibraryFolderID: UUID? {
        if case .folder(let id) = librarySelection { return id }
        return nil
    }

    /// Open the New Document sheet, optionally filing the result into a library folder.
    func openNewDocumentSheet(folderID: UUID? = nil) {
        pendingNewDocumentFolder = folderID
        showNewDocument = true
    }

    /// Create a new document from the dialog: one folder named after the document,
    /// with a same-named main .tex inside the configured default location.
    func createNewDocument(named name: String, projectName: String? = nil, template: DocumentTemplate?, in chosenDirectory: URL? = nil) {
        do {
            let source = template.flatMap { try? library.source(for: $0) } ?? ""
            let directory = chosenDirectory ?? LibraryPreferences.shared.newDocumentDirectory
            let main = try LibraryDocumentCreator.create(named: name, templateSource: source, in: directory)
            let entry = try catalog?.link(main, displayName: projectName ?? name)
            if let entry {
                if let folder = pendingNewDocumentFolder { catalog?.setFolder(entry.id, folderID: folder) }
                catalog?.touch(entry.id)
            }
            pendingNewDocumentFolder = nil
            showNewDocument = false
            prepareToLeaveCurrentTab()
            openProject(main, explicitRoot: true)
            if root?.standardizedFileURL == main.standardizedFileURL { sidebarPage = .structure }
        } catch {
            showError("Could Not Create Document", error.localizedDescription)
        }
    }
    func openPanel(folder: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        panel.message = folder ? "Choose the project folder." : "Choose a LaTeX file."
        if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if folder { openFolder(url) } else { requestOpenProject(url) }
    }
    /// Adopt an existing folder as the project: use its `main.tex`, or ask which file
    /// is the main one. Used by the breadcrumb's parent-folder menu.
    func openFolder(_ url: URL) {
        let candidate = url.appendingPathComponent("main.tex")
        if FileManager.default.fileExists(atPath: candidate.path) { requestOpenProject(candidate) }
        else if let selected = chooseRoot(directory: url) { requestOpenProject(selected, explicitRoot: true) }
    }
    /// User-initiated opens name the project. Tab activation and recovery open it directly.
    func requestOpenProject(_ incoming: URL, explicitRoot: Bool = false) {
        let main = explicitRoot ? incoming : (try? Self.resolveMainFile(incoming).url) ?? incoming
        if catalog?.entry(forMainFile: main) != nil {
            openProject(incoming, explicitRoot: explicitRoot)
            return
        }
        projectNamePrompt = QuillPromptRequest(
            title: "Open Project",
            message: main.deletingLastPathComponent().path,
            initial: incoming.deletingPathExtension().lastPathComponent,
            placeholder: "Project Name",
            confirmTitle: "Open"
        ) { [weak self] name in
            guard let name else { return }
            self?.openProject(incoming, explicitRoot: explicitRoot, projectName: name)
        }
    }

    private func chooseRoot(directory: URL) -> URL? {
        let panel = NSOpenPanel(); panel.directoryURL = directory
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.message = "Choose the main .tex file."; panel.prompt = "Open Project"
        return panel.runModal() == .OK ? panel.url : nil
    }
    // MARK: - Folder access

    /// Whether the project folder can actually be listed. A folder the app may not
    /// read is the one failure mode a user cannot diagnose from the editor alone.
    @discardableResult
    func verifyFolderAccess(prompt: Bool = true) -> Bool {
        guard let directory else { needsFolderAccess = false; return true }
        let readable = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) != nil
        needsFolderAccess = !readable
        if readable { accessPromptedFor = nil }
        else if prompt, accessPromptedFor != directory { accessPromptedFor = directory; promptForFolderAccess() }
        return readable
    }

    func promptForFolderAccess() {
        guard let directory else { return }
        QuillDialogCenter.shared.showConfirm(
            title: "Allow Project Access?",
            message: "Allow access to “\(directory.lastPathComponent)” to open and save project files.",
            confirmTitle: "Grant Access…",
            secondaryTitle: "Open System Settings",
            completion: { [weak self] granted in
                if granted { self?.requestFolderAccess() }
            },
            secondaryCompletion: { [weak self] in self?.openPrivacySettings() })
    }

    /// Asking the user for the folder itself is what grants access to everything in
    /// it: macOS records the selection for the whole directory, not just one file.
    func requestFolderAccess() {
        guard let directory else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory.deletingLastPathComponent()
        panel.message = "Choose “\(directory.lastPathComponent)” to grant project access."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK else { return }
        accessPromptedFor = nil
        verifyFolderAccess(prompt: false)
        refreshIndex(immediate: true)
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") else { return }
        NSWorkspace.shared.open(url)
    }

    struct MainFileResolution {
        let url: URL
        let warning: String?
    }

    /// Only an explicit root directive changes a standalone open's main file.
    /// Invalid directives never prevent opening the original file for editing.
    static func resolveMainFile(_ incoming: URL) throws -> MainFileResolution {
        let incoming = incoming.standardizedFileURL
        var current = incoming
        var seen = Set<URL>()
        do {
            while true {
                guard seen.insert(current).inserted else {
                    throw ProjectError.message("The TeX root directives form a loop.")
                }
                guard current.pathExtension.lowercased() == "tex" else {
                    throw ProjectError.message("The TeX root must refer to a .tex file.")
                }
                let text = try String(contentsOf: current, encoding: .utf8)
                guard let directive = ProjectIndexer.rootDirective(in: text) else { break }
                let path = (directive as NSString).expandingTildeInPath
                let next = URL(fileURLWithPath: path, relativeTo: current.deletingLastPathComponent()).standardizedFileURL
                if next == current { break }
                current = next
            }
            return MainFileResolution(url: current, warning: nil)
        } catch {
            // Fail normally if the file the user actually opened is unreadable.
            _ = try String(contentsOf: incoming, encoding: .utf8)
            return MainFileResolution(url: incoming, warning: "The declared main file could not be used: \(error.localizedDescription)\nThis file is now the main file for this workspace.")
        }
    }

    /// The main file is fixed for this workspace. Opening another project uses
    /// the restoration path to configure a separate workspace root.
    func selectMainFile(_ incoming: URL) throws {
        let main = incoming.standardizedFileURL
        guard root == nil || root == main || restoringSession else {
            throw ProjectError.message("The main file is fixed for this project.")
        }
        if sourceDirectory == nil { sourceDirectory = root?.deletingLastPathComponent() ?? main.deletingLastPathComponent() }
        guard main.pathExtension.lowercased() == "tex" else {
            throw ProjectError.message("Choose a .tex file as the main file.")
        }
        let document: SourceDocument
        if let existing = documents.first(where: { $0.url == main }) { document = existing }
        else { document = SourceDocument(url: main, text: try String(contentsOf: main, encoding: .utf8)) }
        if root == main { activate(document); return }
        rememberCurrentLocation()
        indexTask?.cancel(); indexWorker?.cancel(); generation += 1; isIndexing = false
        syncTask?.cancel(); syncStatusMessage = nil; pdfReadingState = nil
        previewIsOutdated = false; editRevision = 0; buildRevision = 0
        autoCompileTask?.cancel()
        build.resetProject()
        root = main
        documents = [document] + documents.filter { $0.id != document.id }
        previewIsOutdated = documents.contains { $0.isDirty }
        activeID = document.id
        index = ProjectIndex(); expandedNodes = []; selectedNodes = [:]; selectedFolder = nil; folderExpansionOrder = []
        window?.title = "QuillTeX — \(projectTitle(for: main))"
        window?.representedURL = main
        window?.isDocumentEdited = documents.contains { $0.isDirty }
        verifyFolderAccess()
        refreshIndex(immediate: true)
        adoptExistingPDF()
        if !restoringSession, !openingTemplate { maintainProjectRootDirectives(replacingExisting: false) }
        if !openingTemplate {
            do { try library.record(main) } catch { showError("History Not Saved", error.localizedDescription) }
        }
        if !restoringSession, !openingTemplate, let catalog, let entry = try? catalog.link(main) {
            catalog.touch(entry.id)
        }
        sidebarPage = openingTemplate ? .library : .structure
        if !restoringSession { persistSession(force: true); sessionStore.flush() }
        scheduleSessionSave()
    }

    /// Open a document or project as this window's workspace. Opening another tab
    /// or document is not a close: the current tab hands its unsaved drafts to the
    /// session and no close confirmation interrupts the switch. Only an explicit
    /// close intent (closing a tab, window or app) passes `closeIntent: true`.
    /// Templates open through the same path with `asTemplate: true`, which skips
    /// root-directive maintenance, history and catalog links for the template file.
    @discardableResult
    func openProject(_ incoming: URL, explicitRoot: Bool = false, closeIntent: Bool = false,
                     asTemplate: Bool = false, projectName: String? = nil) -> Bool {
        guard commitSidebarNameEdit() else { return false }
        let incoming = incoming.standardizedFileURL
        let wasOpeningTemplate = openingTemplate
        openingTemplate = openingTemplate || asTemplate
        defer { openingTemplate = wasOpeningTemplate }
        do {
            let recoverableMain = !FileManager.default.fileExists(atPath: incoming.path)
                && sessionStore.load(root: incoming)?.documents.contains(where: { $0.path == incoming.path && $0.draft != nil }) == true
            let resolution = explicitRoot || recoverableMain ? MainFileResolution(url: incoming, warning: nil) : try Self.resolveMainFile(incoming)
            let main = resolution.url
            if root == main {
                openSource(incoming)
            } else {
                let savedSession = sessionStore.load(root: main)
                let mainText: String
                do { mainText = try String(contentsOf: main, encoding: .utf8) }
                catch {
                    guard let draft = savedSession?.documents.first(where: { $0.path == main.path })?.draft else { throw error }
                    mainText = draft
                }
                if closeIntent {
                    guard confirmClose(documents) else { return false }
                    if !documents.isEmpty { persistSession(includeDrafts: false) }
                } else {
                    // Keep the outgoing tab's unsaved edits recoverable; the session
                    // draft is never overwritten by a later includeDrafts:false save.
                    prepareToLeaveCurrentTab()
                }
                restoringSession = true
                defer { restoringSession = false; scheduleSessionSave() }
                sessionClosed = false
                sourceDirectory = main.deletingLastPathComponent()
                if ProjectIndexer.isWithin(main, directory: incoming.deletingLastPathComponent()) {
                    sourceDirectory = incoming.deletingLastPathComponent()
                }
                recoveryMessage = nil
                documents = []; history = []; historyPosition = -1
                documents = [SourceDocument(url: main, text: mainText)]
                editorFraction = 0.5
                try selectMainFile(main)
                history = [EditorLocation(url: main, offset: 0)]; historyPosition = 0
                restoreSession(savedSession)
                if incoming != main { openSource(incoming) }
            }
            if !openingTemplate { maintainProjectRootDirectives(replacingExisting: explicitRoot) }
            if let warning = resolution.warning { showError("Main File Directive", warning) }
            if !openingTemplate, let catalog {
                do {
                    let entry = try catalog.link(main, displayName: projectName)
                    catalog.touch(entry.id)
                } catch {
                    if projectName != nil { showError("Project Name Not Saved", error.localizedDescription) }
                }
            }
            window?.title = "QuillTeX — \(projectTitle(for: main))"
            registerDocumentTab(for: main)
            return true
        } catch {
            showError("Could Not Open Project", error.localizedDescription)
            return false
        }
    }

    func openSource(_ url: URL, offset: Int? = nil, recordHistory: Bool = true) {
        guard commitSidebarNameEdit() else { return }
        let url = url.standardizedFileURL
        if !texProjectEnabled, recordHistory, url != root,
           let resolution = try? Self.resolveMainFile(url), resolution.url != root {
            openProject(url)
            return
        }
        do {
            if recordHistory { rememberCurrentLocation() }
            if activeDocument?.url != url {
                activeDocument?.pendingHighlightedLine = nil
                activeDocument?.editorSurface?.textView.clearSourceLineHighlight()
                syncTask?.cancel(); syncStatusMessage = nil
            }
            activeDocument?.editorSurface?.textView.breakUndoCoalescing()
            let doc: SourceDocument
            if let existing = documents.first(where: { $0.url == url }) { doc = existing }
            else { doc = SourceDocument(url: url, text: try String(contentsOf: url, encoding: .utf8)); documents.append(doc) }
            activeID = doc.id
            scheduleSessionSave()
            if paneMode == .preview { paneMode = .split }
            if let offset {
                doc.restoresEditorPosition = false
                doc.selection = NSRange(location: min(max(0, offset), (doc.text as NSString).length), length: 0)
                doc.editorSurface?.navigate(to: doc.selection)
            }
            if recordHistory {
                let next = EditorLocation(url: url, offset: doc.selection.location)
                if history.indices.contains(historyPosition), history[historyPosition] == next { return }
                history = Array(history.prefix(historyPosition + 1)); history.append(next); historyPosition = history.count - 1
            }
        } catch {
            if ProjectIndexer.isPermissionError(error) { verifyFolderAccess() }
            else { showError("Could Not Open File", error.localizedDescription) }
        }
    }
    func activate(_ doc: SourceDocument) { openSource(doc.url) }

    /// UTF-16 offset of the first character of a one-based line.
    static func offset(ofLine line: Int, in text: String) -> Int {
        guard line > 1 else { return 0 }
        let ns = text as NSString
        var position = 0, current = 1
        while current < line, position < ns.length {
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: position, length: 0)))
            if next <= position { break }
            position = next; current += 1
        }
        return min(position, ns.length)
    }

    /// Opens a file at a one-based line — used by SyncTeX inverse search.
    func openSource(_ url: URL, line: Int) {
        let standardized = url.standardizedFileURL
        let text = documents.first { $0.url == standardized }?.text
            ?? (try? String(contentsOf: standardized, encoding: .utf8))
        guard let text else { return }
        openSource(standardized, offset: Self.offset(ofLine: line, in: text))
    }

    // MARK: - SyncTeX

    // MARK: - Compile choices

    /// Engine and strategy are remembered per project, falling back to the global
    /// default for a project that has never chosen one.
    var engine: BuildEngine {
        get { BuildSettings.shared.engine(forProject: directory) }
        set { BuildSettings.shared.setEngine(newValue, forProject: directory); objectWillChange.send() }
    }

    var strategy: BuildStrategy {
        get { BuildSettings.shared.strategy(forProject: directory) }
        set { BuildSettings.shared.setStrategy(newValue, forProject: directory); objectWillChange.send() }
    }

    var canSync: Bool { BuildSettings.shared.synctexPath != nil && build.pdfURL != nil }
    private func labelNode(for diagnostic: BuildDiagnostic) -> NavigationNode? {
        guard diagnostic.category == .references, let key = diagnostic.relatedKey else { return nil }
        func find(_ nodes: [NavigationNode]) -> NavigationNode? {
            for node in nodes {
                if node.kind == .label && node.title == key { return node }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return find(index.structure)
    }
    func resolvedDiagnostic(_ diagnostic: BuildDiagnostic) -> BuildDiagnostic? {
        if let file = diagnostic.file, ["tex", "sty", "cls", "bib"].contains(file.pathExtension.lowercased()) {
            var located = diagnostic; located.line = diagnostic.line ?? 1
            return located
        }
        guard let label = labelNode(for: diagnostic), let file = label.url else { return nil }
        var located = diagnostic; located.file = file; located.line = 1
        return located
    }
    func openDiagnostic(_ diagnostic: BuildDiagnostic) {
        build.selectDiagnostic(diagnostic)
        if let label = labelNode(for: diagnostic), diagnostic.message.localizedCaseInsensitiveContains("multiply"), let file = label.url {
            openSource(file, offset: label.offset)
        } else if let located = resolvedDiagnostic(diagnostic), let file = located.file {
            openSource(file, line: located.line ?? 1)
        } else { return }
        if diagnostic.category.isProofreading, canSync, let document = activeDocument {
            syncSourceToPDF(line: EditorSurface.lineNumber(atCharacter: document.selection.location, in: document.text))
        }
    }
    func navigateDiagnostic(_ offset: Int) {
        let candidates = build.diagnostics.compactMap(resolvedDiagnostic)
        guard let diagnostic = build.neighboringDiagnostic(offset: offset, in: candidates) else { return }
        sidebarVisible = true; sidebarMode = .result
        openDiagnostic(diagnostic)
    }

    /// Show a source line in the PDF: used by ⌘-click and by sidebar navigation.
    /// Does nothing when the project has never been built, which keeps those gestures
    /// harmless before the first compile.
    func syncSourceToPDF(line: Int) {
        guard let document = activeDocument else { return }
        guard let pdf = build.pdfURL else { syncStatusMessage = "Build the PDF first"; return }
        guard let synctex = BuildSettings.shared.synctexPath else { syncStatusMessage = "SyncTeX tool not configured"; return }
        syncTask?.cancel(); syncStatusMessage = "Locating in PDF…"
        let source = document.url, main = root, version = build.pdfVersion
        syncTask = Task { [weak self] in
            do {
                let found = try await SyncTeXService.forward(line: line, file: source, pdf: pdf, executable: synctex)
                guard !Task.isCancelled, let self, self.root == main, self.build.pdfVersion == version else { return }
                if self.paneMode == .editor { self.paneMode = .split }
                self.build.highlight(page: found.page, point: found.point, width: found.width, height: found.height)
                self.syncStatusMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.syncStatusMessage = error.localizedDescription
            }
        }
    }

    /// ⌘-click in the PDF: open the matching source line.
    func syncPDFToSource(page: Int, point: CGPoint) {
        guard let pdf = build.pdfURL else { syncStatusMessage = "Build the PDF first"; return }
        guard let synctex = BuildSettings.shared.synctexPath else { syncStatusMessage = "SyncTeX tool not configured"; return }
        syncTask?.cancel(); syncStatusMessage = "Locating source…"
        let main = root, version = build.pdfVersion, sourceDirectory = directory
        syncTask = Task { [weak self] in
            do {
                let found = try await SyncTeXService.inverse(page: page, x: point.x, y: point.y, pdf: pdf, executable: synctex, sourceDirectory: sourceDirectory)
                guard !Task.isCancelled, let self, self.root == main, self.build.pdfVersion == version else { return }
                self.openSource(found.file, line: found.line)
                if let document = self.activeDocument, document.url == found.file.standardizedFileURL {
                    if let surface = document.editorSurface { surface.textView.highlightSourceLine(found.line) }
                    else { document.pendingHighlightedLine = found.line }
                }
                self.syncStatusMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.syncStatusMessage = error.localizedDescription
            }
        }
    }
    func navigate(_ node: NavigationNode) {
        selectedNodes[sidebarMode] = node.id
        guard let url = node.url else { return }
        if node.kind == .folder || node.kind == .group { return }
        if node.kind == .resource { NSWorkspace.shared.open(url); return }
        openSource(url, offset: node.offset)
        // Sections and labels are positions inside the document, so the preview
        // follows: clicking one shows the page it lives on.
        if node.kind == .section || node.kind == .label || node.kind == .figure || node.kind == .table {
            let text = documents.first { $0.url == url.standardizedFileURL }?.text ?? ""
            syncSourceToPDF(line: EditorSurface.lineNumber(atCharacter: node.offset, in: text))
        }
    }
    private func rememberCurrentLocation() {
        if let doc = activeDocument, history.indices.contains(historyPosition) {
            history[historyPosition] = EditorLocation(url: doc.url, offset: doc.selection.location)
        }
    }
    func moveHistory(_ delta: Int) {
        let target = historyPosition + delta
        guard history.indices.contains(target) else { return }
        rememberCurrentLocation(); historyPosition = target
        let location = history[target]; openSource(location.url, offset: location.offset, recordHistory: false)
    }
    func edited(_ doc: SourceDocument) {
        guard !maintainingRootDirectives else { return }
        if pendingRootDirectives.contains(doc.url), !doc.hasMarkedText {
            maintainProjectRootDirectives(replacingExisting: true)
        }
        editRevision += 1; previewIsOutdated = true
        scheduleSessionSave()
        objectWillChange.send()
        let dirty = documents.contains { $0.isDirty }
        if window?.isDocumentEdited != dirty { window?.isDocumentEdited = dirty }
        refreshIndex()
        scheduleAutoCompile()
    }
    @discardableResult func save(_ doc: SourceDocument) -> Bool {
        guard !doc.hasMarkedText else { showError("Finish Typing First", "Confirm the current input before saving."); return false }
        do {
            let current = try? String(contentsOf: doc.url, encoding: .utf8)
            if let current, current != doc.diskText {
                guard reconcile(doc, with: current) else { return false }
                if !doc.isDirty {
                    objectWillChange.send(); window?.isDocumentEdited = documents.contains { $0.isDirty }
                    refreshIndex(immediate: true)
                    return true
                }
            } else if current == nil {
                guard QuillDialog.confirm(title: "File Changed on Disk",
                                          message: "“\(doc.url.lastPathComponent)” is missing or unreadable. Replace it with your edits?",
                                          confirmTitle: "Overwrite") else { return false }
            }
            try doc.text.write(to: doc.url, atomically: true, encoding: .utf8)
            doc.savedText = doc.text; doc.diskText = doc.text
            objectWillChange.send(); window?.isDocumentEdited = documents.contains { $0.isDirty }
            refreshIndex(immediate: true); scheduleSessionSave(); return true
        } catch {
            if ProjectIndexer.isPermissionError(error) { verifyFolderAccess(prompt: false); promptForFolderAccess() }
            else { showError("Could Not Save", error.localizedDescription) }
            return false
        }
    }
    func updateActiveFile(_ destination: URL, tags: [String]) throws {
        guard let doc = activeDocument else { return }
        let previousProjectFiles = projectTeXFiles
        let oldURL = doc.url
        try updateDocumentFile(from: oldURL, to: destination, tags: tags)
        doc.url = destination
        if root == oldURL {
            root = destination
            try? library.record(destination)
            renameBuildArtifacts(from: oldURL, to: destination)
        }
        updateFileMonitoring()
        history = history.map { $0.url == oldURL ? EditorLocation(url: destination, offset: $0.offset) : $0 }
        indexCache.invalidateInventory()
        if selectedFolder == oldURL.deletingLastPathComponent() { selectedFolder = destination.deletingLastPathComponent() }
        objectWillChange.send()
        refreshIndex(immediate: true)
        updateProjectReferences(from: oldURL, to: destination, files: previousProjectFiles.filter { $0 != oldURL } + [destination])
        if root == destination { maintainProjectRootDirectives(replacingExisting: true, additionalFiles: previousProjectFiles.filter { $0 != oldURL } + [destination]) }
        persistSession(force: true); sessionStore.flush()
    }

    /// LaTeX writes its outputs beside the main document with the same base name.
    /// Renaming the main file carries the compiled PDF and auxiliary files along,
    /// so the preview, SyncTeX and next compile keep using one set of outputs.
    private static let buildArtifactExtensions = [
        "pdf", "aux", "log", "out", "toc", "lof", "lot", "nav", "snm", "vrb",
        "synctex", "synctex.gz", "fls", "fdb_latexmk", "xdv", "dvi", "ps",
        "bbl", "blg", "bcf", "run.xml", "idx", "ind", "ilg", "glo", "gls", "glg",
        "acn", "acr", "alg", "loa"
    ]

    private func renameBuildArtifacts(from oldMain: URL, to newMain: URL) {
        let oldBase = oldMain.deletingPathExtension().lastPathComponent
        let newBase = newMain.deletingPathExtension().lastPathComponent
        guard !oldBase.isEmpty, !newBase.isEmpty, oldBase != newBase else { return }
        let output = buildOutputDirectory.standardizedFileURL
        let fileManager = FileManager.default
        var renamedPDF: URL?
        for suffix in Self.buildArtifactExtensions {
            let source = output.appendingPathComponent(oldBase + "." + suffix)
            let destination = output.appendingPathComponent(newBase + "." + suffix)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path) else { continue }
            do {
                try fileManager.moveItem(at: source, to: destination)
                if suffix == "pdf" { renamedPDF = destination }
            } catch {}
        }
        if let renamedPDF { build.followRenamedPDF(renamedPDF) }
    }

    @discardableResult
    func renameProjectFile(_ url: URL, to proposedName: String) throws -> URL {
        guard let directory, ProjectIndexer.isWithin(url, directory: directory) else {
            throw ProjectError.message("Choose a file inside this project.")
        }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), !name.contains("\n"), !name.contains("\r") else {
            throw ProjectError.message("Enter a file name without path separators or line breaks.")
        }
        let filename = (name as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? name + "." + url.pathExtension : name
        let destination = url.deletingLastPathComponent().appendingPathComponent(filename).standardizedFileURL
        guard destination != url else { return url }
        let previousProjectFiles = projectTeXFiles
        let doc = documents.first { $0.url == url }
        guard doc?.hasMarkedText != true else { throw ProjectError.message("Finish the current input method composition before renaming.") }
        let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        try updateDocumentFile(from: url, to: destination, tags: tags)
        doc?.url = destination
        if root == url {
            root = destination
            try? library.record(destination)
            window?.representedURL = destination
            renameBuildArtifacts(from: url, to: destination)
        }
        history = history.map { $0.url == url ? EditorLocation(url: destination, offset: $0.offset) : $0 }
        selectedNodes[.folder] = "file:" + destination.path
        updateFileMonitoring(); indexCache.invalidateInventory()
        updateProjectReferences(from: url, to: destination, files: previousProjectFiles.filter { $0 != url } + [destination])
        if root == destination {
            maintainProjectRootDirectives(replacingExisting: true,
                additionalFiles: previousProjectFiles.filter { $0 != url } + [destination])
        }
        refreshIndex(immediate: true); persistSession(force: true); sessionStore.flush()
        return destination
    }

    @discardableResult
    func trashProjectFile(_ url: URL) throws -> Bool {
        guard let directory, ProjectIndexer.isWithin(url, directory: directory),
              (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory != true else {
            throw ProjectError.message("Choose a file inside this project.")
        }
        let deletingMain = url == root
        let affected = deletingMain ? documents : documents.filter { $0.url == url }
        guard confirmClose(affected) else { return false }
        try moveFileToTrash(url)
        if deletingMain {
            persistSession(includeDrafts: false); sessionStore.flush()
            build.resetProject()
            indexTask?.cancel(); indexWorker?.cancel(); syncTask?.cancel(); autoCompileTask?.cancel()
            generation += 1; isIndexing = false
            root = nil; sourceDirectory = nil; documents = []; activeID = nil
            index = ProjectIndex(); history = []; historyPosition = -1
            selectedNodes = [:]; expandedNodes = []; selectedFolder = nil; folderExpansionOrder = []
            pdfReadingState = nil; syncStatusMessage = nil
            window?.representedURL = nil
        } else {
            documents.removeAll { $0.url == url }
            if !documents.contains(where: { $0.id == activeID }) { activeID = documents.first?.id }
            history = history.filter { $0.url != url }
            historyPosition = min(historyPosition, history.count - 1)
            selectedNodes[.folder] = nil
            indexCache.invalidateInventory(); refreshIndex(immediate: true)
            persistSession(force: true); sessionStore.flush()
        }
        window?.isDocumentEdited = documents.contains { $0.isDirty }
        return true
    }

    var moveFileToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    static func updatingFileReferences(in text: String, owner: URL, from old: URL, to new: URL) -> String {
        let clean = ProjectIndexer.masked(text)
        let matches = ProjectIndexer.matches(#"\\(?:input|include|subfile|includegraphics|addbibresource|bibliography)\*?(?:\[[^\]\r\n]*\])?[\t ]*\{([^{}\r\n]+)\}"#, in: clean)
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let range = match.range(at: 1)
            let original = (text as NSString).substring(with: range)
            let parts = original.components(separatedBy: ",").map { part -> String in
                let path = part.trimmingCharacters(in: .whitespaces)
                guard !path.contains("\\"), !path.contains("#") else { return part }
                let target = URL(fileURLWithPath: path, relativeTo: owner.deletingLastPathComponent()).standardizedFileURL
                let hasExtension = !(path as NSString).pathExtension.isEmpty
                let resolved = hasExtension ? target : target.appendingPathExtension(old.pathExtension)
                guard resolved.path == old.standardizedFileURL.path else { return part }
                let replacement = path.hasPrefix("/") ? new.path : relativeFilePath(to: new, from: owner.deletingLastPathComponent())
                let final = hasExtension ? replacement : (replacement as NSString).deletingPathExtension
                return part.replacingOccurrences(of: path, with: final)
            }
            result.replaceCharacters(in: range, with: parts.joined(separator: ","))
        }
        return result as String
    }

    private func updateProjectReferences(from old: URL, to new: URL, files: [URL]) {
        guard old != new else { return }
        let wasMaintaining = maintainingRootDirectives
        maintainingRootDirectives = true
        defer { maintainingRootDirectives = wasMaintaining }
        for file in files where file.pathExtension.lowercased() == "tex" {
            do {
                let doc = documents.first { $0.url == file }
                if doc?.hasMarkedText == true { continue }
                var disk = try String(contentsOf: file, encoding: .utf8)
                if let doc, disk != doc.diskText {
                    guard reconcile(doc, with: disk) else { continue }
                    disk = try String(contentsOf: file, encoding: .utf8)
                }
                let updated = Self.updatingFileReferences(in: disk, owner: file, from: old, to: new)
                if disk != updated {
                    guard try String(contentsOf: file, encoding: .utf8) == disk else { continue }
                    try updated.write(to: file, atomically: true, encoding: .utf8)
                }
                if let doc {
                    let buffer = Self.updatingFileReferences(in: doc.text, owner: file, from: old, to: new)
                    doc.savedText = updated; doc.diskText = updated
                    applyMetadataText(buffer, to: doc)
                }
            } catch { recoveryMessage = "Could not update file references in " + file.lastPathComponent }
        }
    }

    func saveActive() {
        guard let doc = activeDocument, save(doc) else { return }
        compileAfterExplicitSave()
    }
    func saveAllFromCommand() {
        guard saveAll() else { return }
        compileAfterExplicitSave()
    }
    private func compileAfterExplicitSave() {
        guard BuildSettings.shared.mode == .manual, BuildSettings.shared.compileOnSave else { return }
        buildNow()
    }
    /// Returns false as soon as one document cannot be written, so a compile never
    /// runs against half-saved sources.
    @discardableResult
    func saveAll() -> Bool {
        for doc in documents where doc.isDirty {
            if !save(doc) { return false }
        }
        return true
    }
    func confirmClose(_ docs: [SourceDocument]) -> Bool {
        guard commitSidebarNameEdit() else { return false }
        if let closeConfirmationHandler { return closeConfirmationHandler(docs) }
        let dirty = docs.filter { $0.isDirty }
        guard !dirty.isEmpty else { return true }
        let names = dirty.map { $0.url.lastPathComponent }.joined(separator: "\n")
        let choice = QuillDialog.present(
            title: "Save Changes Before Closing?",
            width: 420,
            actions: [.primary("Save"),
                      .destructive("Discard Changes", code: 2)]) {
            QuillDialogMessage(names)
        }
        switch choice {
        case 1:
            let saved = dirty.allSatisfy { save($0) }
            if saved { persistSession(); sessionStore.flush() }
            return saved
        case 2: return true
        default: return false
        }
    }
    func close(_ doc: SourceDocument) {
        guard doc.url != root, confirmClose([doc]) else { return }
        if activeID == doc.id {
            syncTask?.cancel(); syncStatusMessage = nil
            activeID = documents.first?.id
        }
        documents.removeAll { $0.id == doc.id }
        persistSession(force: true); sessionStore.flush()
        window?.isDocumentEdited = documents.contains { $0.isDirty }
        refreshIndex(immediate: true)
    }
    // MARK: - Building

    /// Where the compiler writes: "." is the folder the main file lives in (the
    /// default), any other relative value becomes a folder inside the project, and an
    /// absolute path is used as is.
    var buildOutputDirectory: URL {
        let configured = (BuildSettings.shared.outputDirectory as NSString).expandingTildeInPath
        if configured.hasPrefix("/") { return URL(fileURLWithPath: configured) }
        let base = directory ?? URL(fileURLWithPath: NSTemporaryDirectory())
        if configured.isEmpty || configured == "." { return base }
        return base.appendingPathComponent(configured)
    }

    var expectedPDF: URL? {
        guard let root else { return nil }
        return buildOutputDirectory.appendingPathComponent(root.deletingPathExtension().lastPathComponent + ".pdf")
    }

    /// Manual compile: save everything first, and stop if any save fails.
    func buildNow() {
        guard !isEditingTemplate else { return }
        guard let root else { return }
        let preflight = BuildSettings.shared.preflight(engine: engine, strategy: strategy)
        guard preflight.isReady else {
            showError("Compile Tools Missing", preflight.message)
            return
        }
        guard saveAll() else { return }
        let settings = BuildSettings.shared
        build.compile(BuildController.Request(mainFile: root,
                                              outputDirectory: buildOutputDirectory,
                                              engine: engine,
                                              steps: strategy.steps,
                                              toolPaths: settings.toolchain.paths,
                                              environment: settings.environment,
                                              sourceRevision: editRevision))
    }

    /// AUTO mode: save after typing settles, then compile after a second pause.
    func scheduleAutoCompile() {
        guard BuildSettings.shared.mode == .auto, root != nil else { return }
        autoCompileTask?.cancel()
        autoCompileTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BuildSettings.shared.autoSaveDelay))
            guard !Task.isCancelled, let self, self.root != nil else { return }
            // Never save or build in the middle of an input method composition.
            guard !self.documents.contains(where: { $0.hasMarkedText }) else { return }
            guard self.saveAll() else { return }
            try? await Task.sleep(for: .seconds(BuildSettings.shared.autoCompileDelay))
            guard !Task.isCancelled, self.root != nil else { return }
            self.buildNow()
        }
    }

    /// Shows a PDF left behind by an earlier session without compiling again.
    func adoptExistingPDF() {
        autoCompileTask?.cancel()
        guard let pdf = expectedPDF, FileManager.default.fileExists(atPath: pdf.path) else { return }
        build.adoptExistingPDF(pdf)
        previewIsOutdated = previewIsOutdated || sourcesAreNewerThanPDF(documents.map(\.url))
    }

    private func sourcesAreNewerThanPDF(_ urls: [URL]) -> Bool {
        guard let pdf = build.pdfURL,
              let date = try? pdf.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return urls.contains { url in
            guard let changed = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
            return changed > date
        }
    }

    func refreshIndex(immediate: Bool = false) {
        indexTask?.cancel(); indexWorker?.cancel(); generation += 1
        let token = generation
        guard let root else { return }
        let snapshots = Dictionary(uniqueKeysWithValues: documents.map { ($0.url, $0.text) })
        indexTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return }
            self?.isIndexing = true
            guard let self else { return }
            let cache = self.indexCache
            let worker = Task.detached(priority: .userInitiated) { ProjectIndexer(root: root, overrides: snapshots, cache: cache).build() }
            self.indexWorker = worker
            let result = await worker.value
            guard !Task.isCancelled, token == self.generation else { return }
            self.index = result; self.isIndexing = false
            func sourceURLs(_ nodes: [NavigationNode]) -> [URL] {
                nodes.flatMap { node in (node.kind == .source ? node.url.map { [$0] } ?? [] : []) + sourceURLs(node.children) }
            }
            if self.sourcesAreNewerThanPDF(sourceURLs(result.subfiles) + [root]) { self.previewIsOutdated = true }
        }
    }
    func checkExternalChanges() {
        indexCache.invalidateInventory()
        guard !checkingExternal else { externalCheckPending = true; return }
        checkingExternal = true
        defer {
            checkingExternal = false
            if externalCheckPending { externalCheckPending = false; fileMonitor.requestCheck() }
        }
        for doc in documents {
            guard let text = try? String(contentsOf: doc.url, encoding: .utf8), text != doc.diskText else { continue }
            if doc.hasMarkedText { fileMonitor.requestCheck(); continue }
            _ = reconcile(doc, with: text)
        }
        refreshExternalPDF()
        objectWillChange.send(); window?.isDocumentEdited = documents.contains { $0.isDirty }
        refreshIndex(immediate: true)
    }

    @discardableResult
    private func reconcile(_ doc: SourceDocument, with external: String) -> Bool {
        var text = external
        while text != doc.diskText {
            if !doc.isDirty || doc.text == text { replace(doc, with: text); return true }
            let choice: ExternalChangeChoice
            if let externalChangeDecision { choice = externalChangeDecision(doc) }
            else {
                let result = QuillDialog.present(
                    title: "External Change Detected",
                    width: 420,
                    actions: [.primary("Keep My Edits"),
                              .secondary("Use External Version", code: 2)]) {
                    QuillDialogMessage("“\(doc.url.lastPathComponent)” changed on disk. Keep your edits or use the external version?")
                }
                choice = result == 2 ? .useExternal : .keepMine
            }
            // The file may change again while the user is deciding. Never accept
            // a stale snapshot, or overwrite a file which disappeared meanwhile.
            guard documents.contains(where: { $0 === doc }),
                  let latest = try? String(contentsOf: doc.url, encoding: .utf8) else { return false }
            if latest != text { text = latest; continue }
            if choice == .useExternal { replace(doc, with: text) }
            else {
                doc.diskText = text; doc.savedText = text
                scheduleSessionSave()
            }
        }
        return true
    }

    private func refreshExternalPDF() {
        // A compiler can briefly truncate its output. Keep displaying the last
        // valid document until the build finishes or a valid external PDF arrives.
        guard !build.status.isRunning, let pdf = expectedPDF,
              let data = try? Data(contentsOf: pdf), data != observedPDFData,
              let document = PDFDocument(data: data), document.pageCount > 0 else { return }
        build.adoptExistingPDF(pdf)
        previewIsOutdated = documents.contains { $0.isDirty } || sourcesAreNewerThanPDF(documents.map(\.url))
    }
    private func replace(_ doc: SourceDocument, with text: String) {
        editRevision += 1; previewIsOutdated = true
        doc.text = text; doc.savedText = text; doc.diskText = text
        let length = (text as NSString).length
        doc.selection.location = min(doc.selection.location, length)
        doc.selection.length = min(doc.selection.length, length - doc.selection.location)
        doc.undoManager.removeAllActions()
        doc.editorSurface?.reloadFromDisk()
        scheduleSessionSave()
    }
}

/// Watch both the file and its directory: many editors save by renaming a new
/// inode over the old one. Re-arm after each settled event so subsequent writes
/// follow the replacement, including files created after opening the workspace.
@MainActor
private final class ProjectFileMonitor {
    private var urls: Set<URL> = []
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var onChange: (() -> Void)?

    func watch(_ urls: Set<URL>, onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard self.urls != urls else { return }
        self.urls = urls
        rearm()
        requestCheck()
    }

    func requestCheck() {
        guard !urls.isEmpty else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rearm()
                self.onChange?()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func rearm() {
        sources.forEach { $0.cancel() }; sources = []
        var paths = urls
        for url in urls {
            var parent = url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
                parent = parent.deletingLastPathComponent()
            }
            paths.insert(parent)
        }
        for url in paths {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.requestCheck() }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }

    func stop() {
        pending?.cancel(); pending = nil
        sources.forEach { $0.cancel() }; sources = []
        urls = []; onChange = nil
    }

    deinit { pending?.cancel(); sources.forEach { $0.cancel() } }
}

enum ProjectError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Move without overwriting another file; roll back a move if metadata cannot be written.
@MainActor
private func updateDocumentFile(from oldURL: URL, to destination: URL, tags: [String]) throws {
    guard destination.pathExtension.lowercased() == oldURL.pathExtension.lowercased() else {
        throw NSError(domain: "DocumentName", code: 2, userInfo: [NSLocalizedDescriptionKey: "Keep the original file extension."])
    }
    let moved = oldURL.standardizedFileURL != destination.standardizedFileURL
    if moved { try FileManager.default.moveItem(at: oldURL, to: destination) }
    do {
        let currentTags = (try? destination.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        if currentTags != tags { try (destination as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
    } catch {
        if moved { try FileManager.default.moveItem(at: destination, to: oldURL) }
        throw error
    }
}
