import Foundation
import Combine
import CryptoKit

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
        case "basic-article": "Article"
        case "basic-report": "Report"
        case "basic-book": "Book"
        case "basic-letter": "Letter"
        case "basic-beamer": "Slides"
        case "数学笔记": "Math Notes"
        case "演示文稿": "Presentation"
        case "空白文稿": "Blank Document"
        default: title
        }
    }
    var summary: String {
        switch title {
        case "basic-article": "A short article to start from"
        case "basic-report": "Report with chapters and sections"
        case "basic-book": "Book and long-form writing"
        case "basic-letter": "A formal letter"
        case "basic-beamer": "Simple presentation slides"
        case "数学笔记": "Definitions, theorems and formulas"
        case "演示文稿": "Minimal Beamer slides"
        case "空白文稿": "Start from the simplest document"
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
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuillTeX", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
            guard let bundled = bundledTemplatesDirectory ?? Bundle.main.url(forResource: "BundledTemplates", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            let defaults = try FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil).filter { $0.pathExtension == "tex" }
            for source in defaults {
                let destination = templatesDirectory.appendingPathComponent(source.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
            }
            // Earlier releases seeded private templates into the local library.
            // Retire only byte-identical copies; edited and imported files stay usable.
            for (name, digest) in Self.retiredDefaults {
                try retireUnmodifiedTemplate(named: name, digest: digest)
            }
            reloadTemplates()
            if FileManager.default.fileExists(atPath: historyURL.path) {
                do { recents = try JSONDecoder().decode([RecentDocument].self, from: Data(contentsOf: historyURL)) }
                catch { historyReadable = false; throw error }
            }
        } catch { storageError = error.localizedDescription }
    }
    private static let retiredDefaults = [
        "academic-article.tex": "214f2e9fb729239d9da612d7bdff720bf4a07d6c4cbf30cea241e41182cad450",
        "academic-beamer.tex": "a9144ca65ed53e5f8971ed076ccac677ff831940808bb38fa0be65cb5f899e7c",
        "academic-ctexart.tex": "9be200f54ef5a2612ab78377d78fae78da650978479a485ea93bf85ecab6affa"
    ]

    /// Keep recoverable copies outside the chooser rather than deleting local files.
    func retireUnmodifiedTemplate(named name: String, digest: String) throws {
        let source = templatesDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let data = try Data(contentsOf: source)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { return }
        let archive = directory.appendingPathComponent("RetiredTemplates", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var destination = archive.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = archive.appendingPathComponent(UUID().uuidString + "-" + name)
        }
        try FileManager.default.moveItem(at: source, to: destination)
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
        try FileManager.default.removeItem(at: template.url)
        reloadTemplates()
    }
    func source(for template: DocumentTemplate) throws -> String {
        try String(contentsOf: template.url, encoding: .utf8)
    }
    /// Import a copy, preserving both the source and any existing template with the same name.
    @discardableResult func importTemplate(_ source: URL) throws -> URL {
        guard source.pathExtension.lowercased() == "tex" else { throw CocoaError(.fileReadUnsupportedScheme) }
        _ = try String(contentsOf: source, encoding: .utf8)
        let name = source.deletingPathExtension().lastPathComponent
        var destination = templatesDirectory.appendingPathComponent(name + ".tex")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = templatesDirectory.appendingPathComponent("\(name) \(suffix).tex"); suffix += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        reloadTemplates()
        return destination
    }
}
