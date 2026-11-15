import Foundation
import Combine

struct RecentDocument: Codable, Identifiable {
    let path: String
    var openedAt: Date
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct DocumentTemplate: Identifiable {
    let url: URL
    var id: String { url.path }
    /// The file name on disk. Templates keep the name the author gave them.
    var title: String { url.deletingPathExtension().lastPathComponent }
    /// Built-in templates get readable names; imported templates keep their names.
    var displayTitle: String {
        switch title {
        case "article": "Article"
        case "report": "Report"
        case "book": "Book"
        case "letter": "Letter"
        case "beamer": "Slides"
        case "数学笔记": "Math Notes"
        case "演示文稿": "Presentation"
        case "blank": "Blank Document"
        default: title
        }
    }
    var summary: String {
        switch title {
        case "article": "A short article to start from"
        case "report": "Report with chapters and sections"
        case "book": "Book and long-form writing"
        case "letter": "A formal letter"
        case "beamer": "Simple presentation slides"
        case "数学笔记": "Definitions, theorems and formulas"
        case "演示文稿": "Minimal Beamer slides"
        case "blank": "Empty file"
        default: "Custom local template"
        }
    }
}

@MainActor
final class DocumentLibrary: ObservableObject {
    static let shared = DocumentLibrary()
    let directory: URL
    var templatesDirectory: URL { directory.appendingPathComponent("Templates", isDirectory: true) }
    var historyURL: URL { directory.appendingPathComponent("RecentDocuments.json") }
    @Published private(set) var recents: [RecentDocument] = []
    @Published private(set) var templates: [DocumentTemplate] = []
    @Published private(set) var storageError: String?
    private var historyReadable = true

    init(directory: URL? = nil, bundledTemplatesDirectory: URL? = nil) {
        let isolatedDirectory = ProcessInfo.processInfo.environment["QUILLTEX_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.directory = directory ?? isolatedDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuillTeX", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
            guard let bundled = bundledTemplatesDirectory ?? Bundle.main.url(forResource: "bundled_templates", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            try migrateTemplateNames()
            let defaults = try FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil).filter { $0.pathExtension == "tex" }
            for source in defaults {
                let destination = templatesDirectory.appendingPathComponent(source.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            }
            do { try restoreRetiredTemplates() }
            catch { storageError = error.localizedDescription }
            // Versions before 1.2.1 shipped a zero-byte blank.tex (and 空白文稿.tex)
            // as built-in templates. That file is removed once on upgrade; a blank
            // template the user creates later, even an empty one, must survive.
            removeLegacyBlankTemplates()
            reloadTemplates()
            if FileManager.default.fileExists(atPath: historyURL.path) {
                do { recents = try JSONDecoder().decode([RecentDocument].self, from: Data(contentsOf: historyURL)) }
                catch { historyReadable = false; throw error }
            }
        } catch { storageError = error.localizedDescription }
    }

    /// One-time upgrade cleanup for the retired built-in blank template. Only a
    /// zero-byte file that matches the previously shipped template is removed; a
    /// customized blank keeps its content and stays a usable template. The marker
    /// keeps a blank created afterwards (New Template starts empty) from ever being
    /// deleted on a later launch.
    private func removeLegacyBlankTemplates() {
        let marker = directory.appendingPathComponent("LegacyBlankTemplateCleanup")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for name in ["blank.tex", "空白文稿.tex"] {
            let url = templatesDirectory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? -1) == 0 else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        try? Data().write(to: marker, options: .atomic)
    }

    /// Rename previous built-ins without overwriting a customized template.
    private func migrateTemplateNames() throws {
        let names = [("basic_article", "article"), ("basic_report", "report"),
                     ("basic_book", "book"), ("basic_letter", "letter"),
                     ("basic_beamer", "beamer")]
        for (oldName, name) in names {
            let aliases = oldName.hasPrefix("basic_") ? [oldName, oldName.replacingOccurrences(of: "_", with: "-")] : [oldName]
            for alias in aliases {
                let source = templatesDirectory.appendingPathComponent(alias + ".tex")
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.moveItem(at: source, to: availableTemplateURL(named: name))
            }
        }
    }

    /// Earlier versions could mistake an explicitly imported template for a retired
    /// default. Bring those files back once, preserving every same-name copy.
    private func restoreRetiredTemplates() throws {
        let archive = directory.appendingPathComponent("RetiredTemplates", isDirectory: true)
        guard FileManager.default.fileExists(atPath: archive.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        for source in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard source.pathExtension.lowercased() == "tex",
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            var name = source.deletingPathExtension().lastPathComponent
            // The old collision handler prepended a UUID to the author's name.
            if name.count > 37, UUID(uuidString: String(name.prefix(36))) != nil,
               name.dropFirst(36).first == "-" { name = String(name.dropFirst(37)) }
            let destination = availableTemplateURL(named: name)
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private func availableTemplateURL(named name: String) -> URL {
        var destination = templatesDirectory.appendingPathComponent(name + ".tex")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = templatesDirectory.appendingPathComponent("\(name) \(suffix).tex"); suffix += 1
        }
        return destination
    }

    func reloadTemplates() {
        do {
            templates = try FileManager.default.contentsOfDirectory(at: templatesDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "tex" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { DocumentTemplate(url: $0) }
        } catch { storageError = error.localizedDescription }
    }
    func record(_ url: URL) throws {
        guard historyReadable else { throw CocoaError(.fileReadCorruptFile) }
        let path = url.standardizedFileURL.path
        var next = recents.filter { $0.path != path }
        next.insert(RecentDocument(path: path, openedAt: Date()), at: 0)
        next = Array(next.prefix(20))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: historyURL, options: .atomic)
        recents = next
    }
    func remove(_ item: RecentDocument) throws {
        guard historyReadable else { throw CocoaError(.fileReadCorruptFile) }
        let next = recents.filter { $0.id != item.id }
        try JSONEncoder().encode(next).write(to: historyURL, options: .atomic)
        recents = next
    }
    /// Forgets every remembered document. The files themselves are untouched; folders
    /// that were opened before will ask for access again next time.
    func clearRecents() throws {
        guard historyReadable else { throw CocoaError(.fileReadCorruptFile) }
        try JSONEncoder().encode([RecentDocument]()).write(to: historyURL, options: .atomic)
        recents = []
    }
    /// Removes a template from the local library. Documents created from it are untouched.
    func deleteTemplate(_ template: DocumentTemplate) throws {
        guard template.url.deletingLastPathComponent().standardizedFileURL == templatesDirectory.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard FileManager.default.fileExists(atPath: template.url.path) else { return }
        try FileManager.default.trashItem(at: template.url, resultingItemURL: nil)
        reloadTemplates()
    }
    func source(for template: DocumentTemplate) throws -> String {
        try String(contentsOf: template.url, encoding: .utf8)
    }
    /// Create a new template inside the app's template library.
    @discardableResult
    func createTemplate(named rawName: String, source: String = "") throws -> DocumentTemplate {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".tex") { name = String(name.dropLast(4)) }
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw NSError(domain: "TemplateName", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a valid template name."])
        }
        let url = availableTemplateURL(named: name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        reloadTemplates()
        return DocumentTemplate(url: url)
    }

    /// Rename a template file in the local template folder.
    @discardableResult
    func renameTemplate(_ template: DocumentTemplate, to rawName: String) throws -> DocumentTemplate {
        guard template.url.deletingLastPathComponent().standardizedFileURL == templatesDirectory.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".tex") { name = String(name.dropLast(4)) }
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw NSError(domain: "TemplateName", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Enter a valid template name."])
        }
        guard name != template.title else { return template }
        let destination = availableTemplateURL(named: name)
        try FileManager.default.moveItem(at: template.url, to: destination)
        reloadTemplates()
        return DocumentTemplate(url: destination)
    }

    /// Save an edited template back to the local template folder.
    func saveTemplate(_ template: DocumentTemplate, source: String) throws {
        guard template.url.deletingLastPathComponent().standardizedFileURL == templatesDirectory.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try source.write(to: template.url, atomically: true, encoding: .utf8)
        reloadTemplates()
    }
    /// Import a copy, preserving both the source and any existing template with the same name.
    @discardableResult func importTemplate(_ source: URL) throws -> URL {
        guard source.pathExtension.lowercased() == "tex" else { throw CocoaError(.fileReadUnsupportedScheme) }
        _ = try String(contentsOf: source, encoding: .utf8)
        let name = source.deletingPathExtension().lastPathComponent
        let destination = availableTemplateURL(named: name)
        try FileManager.default.copyItem(at: source, to: destination)
        reloadTemplates()
        return destination
    }
}
