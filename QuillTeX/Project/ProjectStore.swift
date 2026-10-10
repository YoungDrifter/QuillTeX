import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SourceDocument: ObservableObject, Identifiable {
    let id = UUID()
    @Published var url: URL
    @Published var text: String
    @Published var savedText: String
    var diskText: String
    var selection = NSRange(location: 0, length: 0)
    var scrollOrigin = NSPoint.zero
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
    init(library: DocumentLibrary? = nil) { self.library = library ?? .shared }
    @Published var showLibrary = false
    @Published var showTemplateChooser = false
    @Published var root: URL?
    @Published var documents: [SourceDocument] = []
    @Published var activeID: UUID?
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
    weak var window: NSWindow?

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
    var creationDirectory: URL? {
        guard let directory else { return nil }
        if sidebarMode == .folder, let selectedFolder,
           ProjectIndexer.isWithin(selectedFolder, directory: directory) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: selectedFolder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return selectedFolder
            }
        }
        return directory
    }

    func newFolder() {
        guard let target = creationDirectory else { return }
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Create a folder in \(relativePath(target))."
        let name = NSTextField(string: "New Folder")
        name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = name
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            selectedFolder = try createFolder(named: name.stringValue, in: target)
            selectedNodes[.folder] = selectedFolder.map { "folder:" + $0.path }
            refreshIndex(immediate: true)
        } catch { showError("Could Not Create Folder", error.localizedDescription) }
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
        return target
    }

    func newSubfile() {
        guard let directory else { return }
        let panel = NSSavePanel()
        panel.title = "New Subfile"; panel.prompt = "Create"
        panel.message = "Choose a location inside this project. Use New Folder to create a folder. An input reference will be added to the main file."
        panel.directoryURL = creationDirectory ?? directory; panel.nameFieldStringValue = "Untitled.tex"
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try createSubfile(at: url) }
        catch { showError("Could Not Create Subfile", error.localizedDescription) }
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

    private static func relativeFilePath(to url: URL, from directory: URL) -> String {
        let target = url.standardizedFileURL.pathComponents
        let base = directory.standardizedFileURL.pathComponents
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
        panel.message = "Choose the main .tex file for this project"; panel.prompt = "Set as Main File"
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

    func changeRoot() {
        guard let directory, let choice = chooseRoot(directory: directory) else { return }
        setMainFile(choice)
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
            return MainFileResolution(url: incoming, warning: "The declared main file could not be used: \(error.localizedDescription)\nThis file is now the main file. You can choose another in Folder.")
        }
    }

    func setMainFile(_ url: URL) {
        do { try selectMainFile(url) }
        catch { showError("Could Not Set Main File", error.localizedDescription) }
    }

    /// Promote a buffer without closing or saving any of the other open documents.
    func selectMainFile(_ incoming: URL) throws {
        let main = incoming.standardizedFileURL
        guard main.pathExtension.lowercased() == "tex" else {
            throw ProjectError.message("Choose a .tex file as the main file.")
        }
        let document: SourceDocument
        if let existing = documents.first(where: { $0.url == main }) { document = existing }
        else { document = SourceDocument(url: main, text: try String(contentsOf: main, encoding: .utf8)) }
        if root == main { activate(document); return }
        rememberCurrentLocation()
        indexTask?.cancel(); generation += 1; isIndexing = false
        autoCompileTask?.cancel()
        build.resetProject()
        root = main
        documents = [document] + documents.filter { $0.id != document.id }
        activeID = document.id
        if historyPosition >= 0 {
            history = Array(history.prefix(historyPosition + 1))
            history.append(EditorLocation(url: main, offset: document.selection.location))
            historyPosition = history.count - 1
        }
        index = ProjectIndex(); expandedNodes = []; selectedNodes = [:]; selectedFolder = nil
        window?.title = "QuillTeX — \(main.deletingPathExtension().lastPathComponent)"
        window?.representedURL = main
        window?.isDocumentEdited = documents.contains { $0.isDirty }
        verifyFolderAccess()
        refreshIndex(immediate: true)
        adoptExistingPDF()
        showLibrary = false
        do { try library.record(main) } catch { showError("History Not Saved", error.localizedDescription) }
    }

    func openProject(_ incoming: URL, explicitRoot: Bool = false) {
        let incoming = incoming.standardizedFileURL
        do {
            let resolution = explicitRoot ? MainFileResolution(url: incoming, warning: nil) : try Self.resolveMainFile(incoming)
            let main = resolution.url
            if root == main {
                openSource(incoming)
            } else {
                let mainText = try String(contentsOf: main, encoding: .utf8)
                guard confirmClose(documents) else { return }
                documents = []; history = []; historyPosition = -1
                documents = [SourceDocument(url: main, text: mainText)]
                try selectMainFile(main)
                history = [EditorLocation(url: main, offset: 0)]; historyPosition = 0
                if incoming != main { openSource(incoming) }
            }
            if let warning = resolution.warning { showError("Main File Directive", warning) }
        } catch { showError("Could Not Open Project", error.localizedDescription) }
    }

    func openSource(_ url: URL, offset: Int? = nil, recordHistory: Bool = true) {
        let url = url.standardizedFileURL
        do {
            if recordHistory { rememberCurrentLocation() }
            activeDocument?.editorSurface?.textView.breakUndoCoalescing()
            let doc: SourceDocument
            if let existing = documents.first(where: { $0.url == url }) { doc = existing }
            else { doc = SourceDocument(url: url, text: try String(contentsOf: url, encoding: .utf8)); documents.append(doc) }
            activeID = doc.id
            if paneMode == .preview { paneMode = .split }
            if let offset {
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

    /// Show a source line in the PDF: used by ⌘-click and by sidebar navigation.
    /// Does nothing when the project has never been built, which keeps those gestures
    /// harmless before the first compile.
    func syncSourceToPDF(line: Int) {
        guard let synctex = BuildSettings.shared.synctexPath, let pdf = build.pdfURL,
              let document = activeDocument else { return }
        guard let found = SyncTeXService.forward(line: line, file: document.url, pdf: pdf, executable: synctex) else { return }
        if paneMode == .editor { paneMode = .split }
        build.highlight(page: found.page, point: found.point)
    }

    /// ⌘-click in the PDF: open the matching source line.
    func syncPDFToSource(page: Int, point: CGPoint) {
        guard let synctex = BuildSettings.shared.synctexPath, let pdf = build.pdfURL else { return }
        guard let found = SyncTeXService.inverse(page: page, x: point.x, y: point.y, pdf: pdf, executable: synctex) else { return }
        openSource(found.file, line: found.line)
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
        objectWillChange.send()
        window?.isDocumentEdited = documents.contains { $0.isDirty }
        refreshIndex()
        scheduleAutoCompile()
    }
    @discardableResult func save(_ doc: SourceDocument) -> Bool {
        guard !doc.hasMarkedText else { showError("Finish Typing First", "Confirm the current input method candidate before saving."); return false }
        do {
            let current = try? String(contentsOf: doc.url, encoding: .utf8)
            if current != doc.diskText {
                let alert = NSAlert(); alert.messageText = "File Changed on Disk"
                alert.informativeText = "\(doc.url.lastPathComponent) was changed or deleted outside QuillTeX. Overwrite it with the current editor contents?"
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Overwrite")
                guard alert.runModal() == .alertSecondButtonReturn else { return false }
            }
            try doc.text.write(to: doc.url, atomically: true, encoding: .utf8)
            doc.savedText = doc.text; doc.diskText = doc.text
            objectWillChange.send(); window?.isDocumentEdited = documents.contains { $0.isDirty }
            refreshIndex(immediate: true); return true
        } catch {
            if ProjectIndexer.isPermissionError(error) { verifyFolderAccess(prompt: false); promptForFolderAccess() }
            else { showError("Could Not Save", error.localizedDescription) }
            return false
        }
    }
    func updateActiveFile(_ destination: URL, tags: [String]) throws {
        guard let doc = activeDocument else { return }
        let oldURL = doc.url
        try updateDocumentFile(from: oldURL, to: destination, tags: tags)
        doc.url = destination
        if root == oldURL { root = destination; try? library.record(destination) }
        history = history.map { $0.url == oldURL ? EditorLocation(url: destination, offset: $0.offset) : $0 }
        if selectedFolder == oldURL.deletingLastPathComponent() { selectedFolder = destination.deletingLastPathComponent() }
        objectWillChange.send()
        refreshIndex(immediate: true)
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
        let dirty = docs.filter { $0.isDirty }
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes before closing?"
        alert.informativeText = dirty.map { $0.url.lastPathComponent }.joined(separator: "\n")
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard Changes")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return dirty.allSatisfy { save($0) }
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func close(_ doc: SourceDocument) {
        guard doc.url != root, confirmClose([doc]) else { return }
        if activeID == doc.id { activeID = documents.first?.id }
        documents.removeAll { $0.id == doc.id }
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
        guard BuildSettings.shared.toolchain.isReady else {
            showError("No TeX installation found",
                      "QuillTeX could not find latexmk in \(BuildSettings.shared.texBinDirectory). Set the TeX path in Settings, then try again.")
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
                                              environment: settings.environment))
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
    }

    func refreshIndex(immediate: Bool = false) {
        indexTask?.cancel(); generation += 1
        let token = generation
        guard let root else { return }
        let snapshots = Dictionary(uniqueKeysWithValues: documents.map { ($0.url, $0.text) })
        indexTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled else { return }
            self?.isIndexing = true
            let result = await Task.detached(priority: .userInitiated) { ProjectIndexer(root: root, overrides: snapshots).build() }.value
            guard !Task.isCancelled, let self, token == self.generation else { return }
            self.index = result; self.isIndexing = false
        }
    }
    func checkExternalChanges() {
        guard !checkingExternal else { return }
        checkingExternal = true; defer { checkingExternal = false }
        for doc in documents {
            guard let text = try? String(contentsOf: doc.url, encoding: .utf8), text != doc.diskText else { continue }
            if doc.hasMarkedText { continue }
            if doc.isDirty {
                let alert = NSAlert(); alert.messageText = "External Change Detected"
                alert.informativeText = "\(doc.url.lastPathComponent) also has unsaved edits. Keep your edits, or reload the version on disk?"
                alert.addButton(withTitle: "Keep My Edits"); alert.addButton(withTitle: "Reload from Disk")
                if alert.runModal() == .alertSecondButtonReturn { replace(doc, with: text) }
                else { doc.diskText = text; doc.savedText = text }
            } else { replace(doc, with: text) }
        }
        objectWillChange.send(); window?.isDocumentEdited = documents.contains { $0.isDirty }
        refreshIndex(immediate: true)
    }
    private func replace(_ doc: SourceDocument, with text: String) {
        doc.text = text; doc.savedText = text; doc.diskText = text
        doc.editorSurface?.reloadFromDisk()
    }
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
