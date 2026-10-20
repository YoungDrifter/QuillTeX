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
    var isDirty: Bool { text != savedText }
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
    case structure = "Structure", subfiles = "Subfiles", folder = "Folder", result = "Result"
    var id: String { rawValue }
    var icon: String {
        switch self { case .structure: "doc.text"; case .subfiles: "doc.on.doc"; case .folder: "folder"; case .result: "exclamationmark.triangle" }
    }
}
enum PaneMode: Int, CaseIterable { case editor, split, preview }
struct EditorLocation: Equatable { var url: URL; var offset: Int }

@MainActor
final class ProjectStore: ObservableObject {
    let library: DocumentLibrary
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
    private var previewIsOutdated = false
    private let maintainsRootDirectives: Bool
    private var maintainingRootDirectives = false
    private var pendingRootDirectives: Set<URL> = []
    private var sourceDirectory: URL?
    @Published var sidebarWidth: Double = 240
    @Published var editorFraction: Double = 0.5
    @Published var pdfReadingState: PDFReadingState?
    @Published var syncStatusMessage: String?
    @Published var recoveryMessage: String?
    init(library: DocumentLibrary? = nil, maintainsRootDirectives: Bool = true) {
        self.maintainsRootDirectives = maintainsRootDirectives
        let library = library ?? .shared
        self.library = library
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
        BuildSettings.shared.$outputDirectory.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFileMonitoring()
                self?.checkExternalChanges()
            }
        }.store(in: &buildObservers)
    }
    @Published var showLibrary = false
    @Published var showTemplateChooser = false
    @Published var root: URL? { didSet { updateFileMonitoring() } }
    @Published var documents: [SourceDocument] = [] { didSet { updateFileMonitoring() } }
    @Published var activeID: UUID? {
        didSet {
            if activeID != oldValue, oldValue != nil, !restoringSession { tabBarVisibilityOverride = true }
        }
    }
    @Published var index = ProjectIndex()
    @Published var sidebarMode: SidebarMode = .structure
    @Published var sidebarVisible = true
    /// A manual choice belongs to this workspace; nil follows the file count.
    @Published private var tabBarVisibilityOverride: Bool?
    var isTabBarVisible: Bool { tabBarVisibilityOverride ?? (documents.count > 1) }
    func setTabBarVisible(_ visible: Bool) { tabBarVisibilityOverride = visible }
    func toggleTabBar() { setTabBarVisible(!isTabBarVisible) }
    @Published var paneMode: PaneMode = .split
    @Published private(set) var splitLayoutVersion = 0
    func showEditorAndPDF() {
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
    @Published var showFilePicker = false
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
            paneMode: paneMode.rawValue, tabBarVisible: tabBarVisibilityOverride, expandedNodes: Array(expandedNodes),
            sidebarWidth: sidebarWidth, editorFraction: editorFraction, pdf: pdfReadingState, pdfIsOutdated: previewIsOutdated,
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
        sidebarMode = SidebarMode(rawValue: state.sidebarMode) ?? .structure
        paneMode = PaneMode(rawValue: state.paneMode) ?? .split
        tabBarVisibilityOverride = state.tabBarVisible
        expandedNodes = Set(state.expandedNodes)
        sidebarWidth = state.sidebarWidth.isFinite ? min(400, max(180, state.sidebarWidth)) : 240
        editorFraction = state.editorFraction.isFinite ? min(0.85, max(0.15, state.editorFraction)) : 0.5
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
    func createDocument(from template: DocumentTemplate) {
        do {
            let source = try library.source(for: template)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
            panel.nameFieldStringValue = "Untitled.tex"; panel.title = "Save New Document"; panel.prompt = "Create"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try source.write(to: url, atomically: true, encoding: .utf8)
            showTemplateChooser = false
            openProject(url, explicitRoot: true)
        } catch { showError("Could Not Create Document", error.localizedDescription) }
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

    struct MainSubfileReference: Identifiable, Equatable {
        let url: URL
        let commandRange: NSRange
        let lineRange: NSRange
        let command: String
        var id: String { "\(commandRange.location):" + url.path }
    }
    enum SubfilePlacement: Hashable {
        case before(String), after(String), editorOffset(Int), end
    }
    var mainSubfiles: [MainSubfileReference] {
        guard let root, let main = documents.first(where: { $0.url == root }) else { return [] }
        let ns = main.text as NSString
        return ProjectIndexer.matches(#"\\(?:input|include|subfile)(?:\[[^\]\r\n]*\])?\s*\{([^{}\r\n]+)\}"#,
            in: ProjectIndexer.masked(main.text)).compactMap { match in
            let path = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !path.contains("\\"), !path.contains("#") else { return nil }
            var url = URL(fileURLWithPath: path, relativeTo: root.deletingLastPathComponent()).standardizedFileURL
            if url.pathExtension.isEmpty { url.appendPathExtension("tex") }
            return MainSubfileReference(url: url, commandRange: match.range,
                lineRange: ns.lineRange(for: match.range), command: ns.substring(with: match.range))
        }
    }
    var unlinkedSubfiles: [URL] {
        let included = Set(mainSubfiles.map { $0.url.resolvingSymlinksInPath().path })
        let mainPath = root?.resolvingSymlinksInPath().path
        return Set(index.texFiles + documents.map(\.url)).filter {
            $0.pathExtension.lowercased() == "tex" && $0.resolvingSymlinksInPath().path != mainPath
                && !included.contains($0.resolvingSymlinksInPath().path)
        }.sorted { relativePath($0).localizedStandardCompare(relativePath($1)) == .orderedAscending }
    }

    @discardableResult
    func insertSubfile(_ url: URL, moving referenceID: String? = nil, at placement: SubfilePlacement) throws -> Bool {
        guard let root, let main = documents.first(where: { $0.url == root }), !main.hasMarkedText,
              let base = sourceDirectory ?? directory, ProjectIndexer.isWithin(url, directory: base),
              url.resolvingSymlinksInPath().path != root.resolvingSymlinksInPath().path,
              url.pathExtension.lowercased() == "tex", FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.message("Choose an existing TeX subfile and finish the current input before inserting it.")
        }
        let references = mainSubfiles
        let ns = main.text as NSString
        var offset: Int
        switch placement {
        case .before(let id), .after(let id):
            guard let reference = references.first(where: { $0.id == id }) else {
                throw ProjectError.message("The main file changed during the drag. Try again.")
            }
            if case .before = placement { offset = reference.lineRange.location }
            else { offset = NSMaxRange(reference.lineRange) }
        case .editorOffset(let point):
            let bounded = min(max(0, point), ns.length)
            offset = bounded == ns.length ? bounded : ns.lineRange(for: NSRange(location: bounded, length: 0)).location
        case .end:
            offset = ProjectIndexer.matches(#"\\end\s*\{document\}"#, in: ProjectIndexer.masked(main.text)).last
                .map { ns.lineRange(for: $0.range).location } ?? ns.length
        }
        let path = Self.relativeFilePath(to: url, from: root.deletingLastPathComponent())
        guard path.rangeOfCharacter(from: CharacterSet(charactersIn: "%#{}\\\r\n")) == nil else {
            throw ProjectError.message("This path cannot be used in a literal LaTeX input command.")
        }
        var insertion = "\\input{\(path)}"
        var text = main.text
        if let referenceID {
            guard let moving = references.first(where: { $0.id == referenceID }) else {
                throw ProjectError.message("The main file changed during the drag. Try again.")
            }
            let prefix = ns.substring(with: NSRange(location: moving.lineRange.location, length: moving.commandRange.location - moving.lineRange.location))
            let tail = ns.substring(with: NSRange(location: NSMaxRange(moving.commandRange), length: NSMaxRange(moving.lineRange) - NSMaxRange(moving.commandRange)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let wholeLine = prefix.trimmingCharacters(in: .whitespaces).isEmpty && (tail.isEmpty || tail.hasPrefix("%"))
            let removal = wholeLine ? moving.lineRange : moving.commandRange
            if offset >= removal.location && offset <= NSMaxRange(removal) { return false }
            insertion = wholeLine ? ns.substring(with: removal).trimmingCharacters(in: .newlines) : moving.command
            text = ns.replacingCharacters(in: removal, with: "")
            if offset > removal.location { offset -= removal.length }
        } else if references.contains(where: { $0.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path }) {
            throw ProjectError.message("This subfile is already included. Drag its existing reference to move it.")
        }
        let newline = main.text.contains("\r\n") ? "\r\n" : "\n"
        let remaining = text as NSString
        let prefix = offset > 0 && remaining.character(at: offset - 1) != 10 && remaining.character(at: offset - 1) != 13 ? newline : ""
        text = remaining.replacingCharacters(in: NSRange(location: offset, length: 0), with: prefix + insertion + newline)
        applyMetadataText(text, to: main, actionName: referenceID == nil ? "Insert Subfile" : "Move Subfile")
        if main.editorSurface == nil { edited(main) }
        refreshIndex(immediate: true)
        return true
    }

    func previewSubfileInsertion(atScreenPoint point: NSPoint) -> Int? {
        guard let root, let doc = activeDocument, doc.url == root, !doc.hasMarkedText,
              let window, let surface = doc.editorSurface else { clearSubfileInsertionPreview(); return nil }
        let view = surface.textView
        let location = view.convert(window.convertPoint(fromScreen: point), from: nil)
        guard view.visibleRect.contains(location), let layout = view.layoutManager, let container = view.textContainer else {
            clearSubfileInsertionPreview(); return nil
        }
        let local = NSPoint(x: location.x - view.textContainerOrigin.x, y: location.y - view.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        let character = local.y >= layout.usedRect(for: container).maxY || glyph >= layout.numberOfGlyphs
            ? view.string.utf16.count : layout.characterIndexForGlyph(at: glyph)
        let ns = view.string as NSString
        let offset = character == ns.length ? ns.length : ns.lineRange(for: NSRange(location: character, length: 0)).location
        view.subfileInsertionOffset = offset
        return offset
    }
    func clearSubfileInsertionPreview() { documents.forEach { $0.editorSurface?.textView.subfileInsertionOffset = nil } }

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
        guard maintainsRootDirectives, !maintainingRootDirectives, let root else { return }
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
    private func applyMetadataText(_ text: String, to doc: SourceDocument, actionName: String = "Update Main File Comment") {
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

    private static func relativeFilePath(to url: URL, from directory: URL) -> String {
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
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.alertStyle = .warning; alert.addButton(withTitle: "OK"); alert.runModal()
    }
    func openPanel(folder: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder; panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        panel.message = folder ? "Choose the project folder that contains your main file" : "Open any LaTeX file; its TeX root directive selects the main file"
        if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if folder { openFolder(url) } else { openProject(url) }
    }
    /// Adopt an existing folder as the project: use its `main.tex`, or ask which file
    /// is the main one. Used by the breadcrumb's parent-folder menu.
    func openFolder(_ url: URL) {
        let candidate = url.appendingPathComponent("main.tex")
        if FileManager.default.fileExists(atPath: candidate.path) { openProject(candidate) }
        else if let selected = chooseRoot(directory: url) { openProject(selected, explicitRoot: true) }
    }
    private func chooseRoot(directory: URL) -> URL? {
        let panel = NSOpenPanel(); panel.directoryURL = directory
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.message = "Choose the main .tex file to open this project"; panel.prompt = "Open Project"
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
        let alert = NSAlert()
        alert.messageText = "QuillTeX needs permission to read this project"
        alert.informativeText = """
        macOS is blocking access to \(directory.path). Grant access to the folder so every \
        file in the project can be opened, indexed and saved.
        """
        alert.addButton(withTitle: "Grant Access…")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: requestFolderAccess()
        case .alertSecondButtonReturn: openPrivacySettings()
        default: break
        }
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
        panel.message = "Choose “\(directory.lastPathComponent)” to let QuillTeX read, index and save the whole project"
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
        window?.title = "QuillTeX — \(main.deletingPathExtension().lastPathComponent)"
        window?.representedURL = main
        window?.isDocumentEdited = documents.contains { $0.isDirty }
        verifyFolderAccess()
        refreshIndex(immediate: true)
        adoptExistingPDF()
        if !restoringSession { maintainProjectRootDirectives(replacingExisting: false) }
        showLibrary = false
        do { try library.record(main) } catch { showError("History Not Saved", error.localizedDescription) }
        if !restoringSession { persistSession(force: true); sessionStore.flush() }
        scheduleSessionSave()
    }

    func openProject(_ incoming: URL, explicitRoot: Bool = false) {
        guard commitSidebarNameEdit() else { return }
        let incoming = incoming.standardizedFileURL
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
                guard confirmClose(documents) else { return }
                persistSession(includeDrafts: false)
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
                try selectMainFile(main)
                history = [EditorLocation(url: main, offset: 0)]; historyPosition = 0
                restoreSession(savedSession)
                if incoming != main { openSource(incoming) }
            }
            maintainProjectRootDirectives(replacingExisting: explicitRoot)
            if let warning = resolution.warning { showError("Main File Directive", warning) }
        } catch { showError("Could Not Open Project", error.localizedDescription) }
    }

    func openSource(_ url: URL, offset: Int? = nil, recordHistory: Bool = true) {
        guard commitSidebarNameEdit() else { return }
        let url = url.standardizedFileURL
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

    /// Reorder buffers without activating them or disturbing their editor state.
    /// The current main file remains pinned at index zero.
    func moveTab(_ id: UUID, to proposedIndex: Int) {
        guard let from = documents.firstIndex(where: { $0.id == id }),
              documents[from].url != root, documents.count > 1 else { return }
        let destination = min(documents.count - 1, max(1, proposedIndex))
        guard from != destination else { return }
        let document = documents.remove(at: from)
        documents.insert(document, at: destination)
        scheduleSessionSave()
    }


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
        guard let pdf = build.pdfURL else { syncStatusMessage = "Compile the document before locating it in the PDF."; return }
        guard let synctex = BuildSettings.shared.synctexPath else { syncStatusMessage = "SyncTeX was not found in the configured TeX folder."; return }
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
        guard let pdf = build.pdfURL else { syncStatusMessage = "Compile the document before locating its source."; return }
        guard let synctex = BuildSettings.shared.synctexPath else { syncStatusMessage = "SyncTeX was not found in the configured TeX folder."; return }
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
        window?.isDocumentEdited = documents.contains { $0.isDirty }
        refreshIndex()
        scheduleAutoCompile()
    }
    @discardableResult func save(_ doc: SourceDocument) -> Bool {
        guard !doc.hasMarkedText else { showError("Finish Typing First", "Confirm the current input method candidate before saving."); return false }
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
                let alert = NSAlert(); alert.messageText = "File Changed on Disk"
                alert.informativeText = "\(doc.url.lastPathComponent) was changed or deleted outside QuillTeX. Overwrite it with the current editor contents?"
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Overwrite")
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
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
        updateFileMonitoring()
        if root == oldURL { root = destination; try? library.record(destination) }
        history = history.map { $0.url == oldURL ? EditorLocation(url: destination, offset: $0.offset) : $0 }
        indexCache.invalidateInventory()
        if selectedFolder == oldURL.deletingLastPathComponent() { selectedFolder = destination.deletingLastPathComponent() }
        objectWillChange.send()
        refreshIndex(immediate: true)
        updateProjectReferences(from: oldURL, to: destination, files: previousProjectFiles.filter { $0 != oldURL } + [destination])
        if root == destination { maintainProjectRootDirectives(replacingExisting: true, additionalFiles: previousProjectFiles.filter { $0 != oldURL } + [destination]) }
        persistSession(force: true); sessionStore.flush()
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
        let dirty = docs.filter { $0.isDirty }
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes before closing?"
        alert.informativeText = dirty.map { $0.url.lastPathComponent }.joined(separator: "\n")
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let saved = dirty.allSatisfy { save($0) }
            if saved { persistSession(); sessionStore.flush() }
            return saved
        case .alertThirdButtonReturn: return true
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
        guard let root else { return }
        let preflight = BuildSettings.shared.preflight(engine: engine, strategy: strategy)
        guard preflight.isReady else {
            showError("Compile Tools Missing", preflight.message)
            return
        }
        guard saveAll() else {
            showError("Could not save", "The compile was cancelled because a file could not be saved.")
            return
        }
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
                let alert = NSAlert()
                alert.messageText = "External Change Detected"
                alert.informativeText = "\(doc.url.lastPathComponent) has changed outside QuillTeX and has unsaved edits here. Choose which version to keep. Keeping your edits leaves the external file unchanged until you save."
                alert.addButton(withTitle: "Keep My Edits")
                alert.addButton(withTitle: "Use External Version")
                choice = alert.runModal() == .alertSecondButtonReturn ? .useExternal : .keepMine
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
