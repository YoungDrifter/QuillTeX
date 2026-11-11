import Foundation
import Combine

/// Where the document library sidebar points: every document, starred documents,
/// one library folder (nil is the built-in Unsorted group) or one tag.
enum LibrarySelection: Hashable {
    case all
    case starred
    case templates
    case newTab
    case folder(UUID?)
    case tag(String)
}

enum LibraryEntryKind: String, Codable {
    /// A folder-based LaTeX project; `path` is its main .tex file.
    case project
    /// A single local .tex file linked into the library.
    case file
}

/// Accent used by a library folder in the sidebar. Existing snapshots have no
/// colour and keep the old positional palette until the user picks one.
enum LibraryFolderColor: String, Codable, CaseIterable, Identifiable {
    case blue, pink, orange, gray, green, purple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blue: "Blue"
        case .pink: "Pink"
        case .orange: "Orange"
        case .gray: "Gray"
        case .green: "Green"
        case .purple: "Purple"
        }
    }
}

struct LibraryFolder: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var color: LibraryFolderColor?
}

/// A link to a local document. The library never owns or moves the file: it only
/// remembers the path plus the user's organisation (folder, star, tags).
struct LibraryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Absolute path of the main .tex file.
    var path: String
    var displayName: String
    var kind: LibraryEntryKind = .file
    /// nil means the entry is in Unsorted.
    var folderID: UUID?
    var tags: [String] = []
    var starred: Bool = false
    var addedAt: Date = Date()
    var lastViewedAt: Date = Date()
    /// Main file modification date, refreshed from disk.
    var updatedAt: Date?
    /// Folder/project creation date on disk, refreshed from disk.
    var createdOnDiskAt: Date?

    var url: URL { URL(fileURLWithPath: path) }
    var folderURL: URL { url.deletingLastPathComponent() }
}

struct LibraryDateGroup: Identifiable {
    var id: String { title }
    let title: String
    let entries: [LibraryEntry]
}

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case name
    case lastViewed
    case added
    case created
    case updated
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .lastViewed: "Last Viewed"
        case .added: "Date Added"
        case .created: "Date Created"
        case .updated: "Date Updated"
        }
    }
}

struct LibrarySnapshot: Codable {
    var version: Int = 1
    var folders: [LibraryFolder] = []
    var entries: [LibraryEntry] = []
}

/// The previous history format owned by `DocumentLibrary`, decoded locally so the
/// catalog never has to depend on that store. Dates use the default JSON encoder
/// representation, matching how `RecentDocument` is written.
private struct LegacyRecentDocument: Decodable {
    let path: String
    let openedAt: Date
}

/// The user's document library. All local files stay where they are; this store
/// only records links and the organisation around them.
@MainActor
final class DocumentCatalog: ObservableObject {
    static let shared = DocumentCatalog()
    static let unsortedTitle = "Unsorted"

    let directory: URL
    var storageURL: URL { directory.appendingPathComponent("DocumentCatalog.json") }
    var legacyHistoryURL: URL { directory.appendingPathComponent("RecentDocuments.json") }

    @Published private(set) var folders: [LibraryFolder] = []
    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var storageError: String?

    /// False only when the snapshot file exists but cannot be decoded. Mutations
    /// must then fail instead of replacing the user's unreadable file.
    private var storageReadable = true

    private let errorDomain = "QuillTeX.DocumentCatalog"

    init(directory: URL? = nil) {
        let isolated = ProcessInfo.processInfo.environment["QUILLTEX_DATA_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let target = directory ?? isolated
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuillTeX", isDirectory: true)
        self.directory = target
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            storageError = error.localizedDescription
        }
        loadInitialSnapshot()
    }

    // MARK: - Persistence

    private func loadInitialSnapshot() {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            loadSnapshotFromDisk()
        } else {
            migrateLegacyHistoryIfNeeded()
        }
    }

    private func loadSnapshotFromDisk() {
        do {
            let data = try Data(contentsOf: storageURL)
            let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
            folders = snapshot.folders
            entries = snapshot.entries
            storageError = nil
            storageReadable = true
            backfillDiskDates()
        } catch {
            // The file may belong to a newer version or be damaged. Keep the user's
            // bytes on disk and refuse to write over them until it is fixed.
            folders = []
            entries = []
            storageError = error.localizedDescription
            storageReadable = false
        }
    }

    /// Older snapshots only knew when a document was linked. Fill the real file
    /// creation/update dates once so Created never shows the import time.
    private func backfillDiskDates() {
        var changed = false
        for index in entries.indices {
            let metadata = diskMetadata(for: entries[index].url, kind: entries[index].kind)
            if entries[index].createdOnDiskAt == nil, let created = metadata.createdOnDiskAt {
                entries[index].createdOnDiskAt = created
                changed = true
            }
            if entries[index].updatedAt == nil, let updated = metadata.updatedAt {
                entries[index].updatedAt = updated
                changed = true
            }
        }
        if changed { persistIfPossible() }
    }

    /// One-time import of `DocumentLibrary`'s old recent-document list. The old
    /// history file is left alone so the previous store keeps working.
    private func migrateLegacyHistoryIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyHistoryURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyHistoryURL),
              let legacy = try? JSONDecoder().decode([LegacyRecentDocument].self, from: data) else { return }
        var seen = Set<String>()
        var imported: [LibraryEntry] = []
        for item in legacy {
            let url = URL(fileURLWithPath: item.path).standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            let kind: LibraryEntryKind = url.lastPathComponent == "main.tex" ? .project : .file
            var entry = LibraryEntry(
                path: url.path,
                displayName: kind == .project ? url.deletingLastPathComponent().lastPathComponent
                                             : url.deletingPathExtension().lastPathComponent,
                kind: kind
            )
            entry.addedAt = item.openedAt
            entry.lastViewedAt = item.openedAt
            imported.append(entry)
        }
        folders = []
        entries = imported
        storageReadable = true
        do {
            try persist()
        } catch {
            storageError = error.localizedDescription
        }
    }

    private func requireReadableStorage() throws {
        guard storageReadable else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func encodedSnapshot() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(LibrarySnapshot(folders: folders, entries: entries))
    }

    private func persist() throws {
        try requireReadableStorage()
        try encodedSnapshot().write(to: storageURL, options: .atomic)
    }

    /// Non-throwing mutations use this: a corrupt snapshot is never overwritten,
    /// and ordinary write failures are reported without undoing in-memory state.
    private func persistIfPossible() {
        guard storageReadable else { return }
        do {
            try persist()
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Queries

    func folder(id: UUID) -> LibraryFolder? {
        folders.first { $0.id == id }
    }

    func entry(id: UUID) -> LibraryEntry? {
        entries.first { $0.id == id }
    }

    func entry(forMainFile url: URL) -> LibraryEntry? {
        let path = url.standardizedFileURL.path
        return entries.first { $0.path == path }
    }

    func entries(inFolder id: UUID?) -> [LibraryEntry] {
        entries.filter { $0.folderID == id }
    }

    var starredEntries: [LibraryEntry] { entries.filter(\.starred) }

    var allTags: [String] {
        Self.normalizedTags(entries.flatMap(\.tags))
    }

    var unsortedEntries: [LibraryEntry] { entries(inFolder: nil) }

    func entries(in selection: LibrarySelection) -> [LibraryEntry] {
        switch selection {
        case .all:
            return entries
        case .starred:
            return starredEntries
        case .templates, .newTab:
            return []
        case .folder(let id):
            return entries(inFolder: id)
        case .tag(let tag):
            let key = tag.lowercased()
            return entries.filter { entry in
                entry.tags.contains { $0.lowercased() == key }
            }
        }
    }

    func sorted(_ entries: [LibraryEntry], by order: LibrarySortOrder) -> [LibraryEntry] {
        switch order {
        case .lastViewed: entries.sorted { $0.lastViewedAt > $1.lastViewedAt }
        case .added: entries.sorted { $0.addedAt > $1.addedAt }
        case .created: entries.sorted { ($0.createdOnDiskAt ?? $0.addedAt) > ($1.createdOnDiskAt ?? $1.addedAt) }
        case .updated: entries.sorted { ($0.updatedAt ?? $0.addedAt) > ($1.updatedAt ?? $1.addedAt) }
        case .name: entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
    }

    /// Finder-style date grouping by the entry's created date (`addedAt`).
    func grouped(_ entries: [LibraryEntry], now: Date = Date(), calendar: Calendar = .current) -> [LibraryDateGroup] {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfLast7Days = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfYesterday
        let startOfLast30Days = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfLast7Days

        var buckets: [[LibraryEntry]] = Array(repeating: [], count: 5)
        for entry in entries {
            let created = entry.createdOnDiskAt ?? entry.addedAt
            if created >= startOfToday {
                buckets[0].append(entry)
            } else if created >= startOfYesterday {
                buckets[1].append(entry)
            } else if created >= startOfLast7Days {
                buckets[2].append(entry)
            } else if created >= startOfLast30Days {
                buckets[3].append(entry)
            } else {
                buckets[4].append(entry)
            }
        }

        let titles = ["Today", "Yesterday", "Last 7 Days", "Last 30 Days", "Earlier"]
        var groups: [LibraryDateGroup] = []
        for (index, title) in titles.enumerated() where !buckets[index].isEmpty {
            groups.append(LibraryDateGroup(title: title, entries: buckets[index]))
        }
        return groups
    }

    func isMissing(_ entry: LibraryEntry) -> Bool {
        !FileManager.default.fileExists(atPath: entry.path)
    }

    // MARK: - Mutations

    @discardableResult
    func link(_ url: URL, displayName: String? = nil) throws -> LibraryEntry {
        try requireReadableStorage()
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw libraryError("The document could not be found at \(standardized.path).")
        }
        let kind: LibraryEntryKind = standardized.lastPathComponent == "main.tex" ? .project : .file
        let name = resolvedDisplayName(displayName, for: standardized, kind: kind)

        if let index = entries.firstIndex(where: { $0.path == standardized.path }) {
            var entry = entries[index]
            // Relinking refreshes presentation and disk facts but keeps the user's
            // position in the library: identity, date added, folder, star, tags and
            // the last-viewed stamp are all preserved.
            entry.displayName = name
            entry.kind = kind
            let metadata = diskMetadata(for: standardized, kind: kind)
            entry.updatedAt = metadata.updatedAt
            entry.createdOnDiskAt = metadata.createdOnDiskAt
            entries[index] = entry
            try persist()
            return entry
        }

        var entry = LibraryEntry(path: standardized.path, displayName: name, kind: kind)
        let metadata = diskMetadata(for: standardized, kind: kind)
        entry.updatedAt = metadata.updatedAt
        entry.createdOnDiskAt = metadata.createdOnDiskAt
        entries.append(entry)
        try persist()
        return entry
    }

    func touch(_ id: UUID) {
        guard storageReadable, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].lastViewedAt = Date()
        persistIfPossible()
    }

    func setStarred(_ id: UUID, _ starred: Bool) {
        guard storageReadable, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].starred = starred
        persistIfPossible()
    }

    func toggleStar(_ id: UUID) {
        setStarred(id, !(entry(id: id)?.starred ?? false))
    }

    func setFolder(_ id: UUID, folderID: UUID?) {
        guard storageReadable, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // Unknown folders (for example one deleted on another screen) become Unsorted.
        let resolved = folderID.flatMap { folder(id: $0) != nil ? $0 : nil }
        entries[index].folderID = resolved
        persistIfPossible()
    }

    func setTags(_ id: UUID, tags: [String]) throws {
        try requireReadableStorage()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].tags = Self.normalizedTags(tags)
        try persist()
    }

    func rename(_ id: UUID, to name: String) throws {
        try requireReadableStorage()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw libraryError("The document name cannot be empty.")
        }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // Only the library label changes; the file on disk keeps its name.
        entries[index].displayName = trimmed
        try persist()
    }

    func removeEntry(_ id: UUID) {
        guard storageReadable else { return }
        entries.removeAll { $0.id == id }
        persistIfPossible()
    }

    @discardableResult
    func createFolder(named name: String, color: LibraryFolderColor? = nil) throws -> LibraryFolder {
        try requireReadableStorage()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw libraryError("The folder name cannot be empty.")
        }
        guard !folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw libraryError("A folder named \"\(trimmed)\" already exists.")
        }
        let folder = LibraryFolder(name: trimmed, color: color)
        folders.append(folder)
        try persist()
        return folder
    }

    /// Changes only the folder's accent. The folder identity, documents and
    /// ordering stay untouched.
    func setFolderColor(_ id: UUID, color: LibraryFolderColor?) {
        guard storageReadable, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        guard folders[index].color != color else { return }
        folders[index].color = color
        persistIfPossible()
    }

    func renameFolder(_ id: UUID, to name: String) throws {
        try requireReadableStorage()
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            throw libraryError("The folder could not be found.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw libraryError("The folder name cannot be empty.")
        }
        guard !folders.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw libraryError("A folder named \"\(trimmed)\" already exists.")
        }
        folders[index].name = trimmed
        try persist()
    }

    func deleteFolder(_ id: UUID) {
        guard storageReadable, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders.remove(at: index)
        // Deleting a folder never deletes documents; they fall back to Unsorted.
        for entryIndex in entries.indices where entries[entryIndex].folderID == id {
            entries[entryIndex].folderID = nil
        }
        persistIfPossible()
    }

    func refreshMetadata() {
        guard storageReadable else { return }
        for index in entries.indices {
            let metadata = diskMetadata(for: entries[index].url, kind: entries[index].kind)
            if let updated = metadata.updatedAt {
                entries[index].updatedAt = updated
            }
            if let created = metadata.createdOnDiskAt {
                entries[index].createdOnDiskAt = created
            }
        }
        // Missing files stay linked, so only metadata is rewritten.
        persistIfPossible()
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            folders = []
            entries = []
            storageError = nil
            storageReadable = true
            return
        }
        loadSnapshotFromDisk()
    }

    // MARK: - Helpers

    private func resolvedDisplayName(_ given: String?, for url: URL, kind: LibraryEntryKind) -> String {
        if let given {
            let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if kind == .project {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func diskMetadata(for url: URL, kind: LibraryEntryKind) -> (updatedAt: Date?, createdOnDiskAt: Date?) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let createdURL = kind == .project ? url.deletingLastPathComponent() : url
        let created = (try? createdURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        return (modified, created)
    }

    private func libraryError(_ message: String) -> NSError {
        NSError(domain: errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Trim, drop empty tags, dedupe case-insensitively (keeping the first spelling)
    /// and sort for display.
    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            guard seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Default location for new documents, configurable in Settings.
@MainActor
final class LibraryPreferences: ObservableObject {
    static let shared = LibraryPreferences()
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuillTeX", isDirectory: true)
    }

    private let defaults: UserDefaults
    private let key = "quilltex.newDocumentDirectory"
    private let lastDirectoryKey = "quilltex.lastNewDocumentDirectory"
    @Published var newDocumentDirectory: URL

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: key).map { URL(fileURLWithPath: $0, isDirectory: true) }
        newDocumentDirectory = stored ?? Self.defaultDirectory
    }

    /// The folder chosen the last time a document was created. It is offered
    /// first in the New Document sheet, independently of the Settings default.
    var lastDocumentDirectory: URL? {
        guard let path = defaults.string(forKey: lastDirectoryKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var newDocumentStartDirectory: URL {
        lastDocumentDirectory ?? newDocumentDirectory
    }

    func rememberLastDocumentDirectory(_ url: URL) {
        defaults.set(url.path, forKey: lastDirectoryKey)
    }

    func setDirectory(_ url: URL) {
        newDocumentDirectory = url
        defaults.set(url.path, forKey: key)
    }

    func resetToDefault() {
        defaults.removeObject(forKey: key)
        newDocumentDirectory = Self.defaultDirectory
    }
}

/// Creates the on-disk shape of a new document: one folder named after the
/// document containing a same-named main .tex file.
enum LibraryDocumentCreator {
    /// Make a user-provided name safe for a single file/folder component.
    static func sanitizedName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Untitled" }

        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\u{0}", with: "-")

        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = trimmingTrailingDotsAndSpaces(name)
        guard !name.isEmpty else { return "Untitled" }

        if name.count > 120 {
            name = String(name.prefix(120))
            name = trimmingTrailingDotsAndSpaces(name)
        }
        return name.isEmpty ? "Untitled" : name
    }

    private static func trimmingTrailingDotsAndSpaces(_ name: String) -> String {
        var result = name
        while let last = result.last, last == "." || last == " " {
            result.removeLast()
        }
        return result
    }

    @discardableResult
    static func create(named rawName: String, templateSource: String, in directory: URL,
                       fileManager: FileManager = .default) throws -> URL {
        let name = sanitizedName(rawName)
        // The parent may not exist yet for a brand-new preference directory.
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Never overwrite an existing file or folder: "Name", "Name 2", "Name 3", …
        var folderURL = directory.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: folderURL.path) {
            folderURL = directory.appendingPathComponent("\(name) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let folderName = folderURL.lastPathComponent
        let mainURL = folderURL.appendingPathComponent(folderName + ".tex", isDirectory: false)
        do {
            try templateSource.write(to: mainURL, atomically: true, encoding: .utf8)
        } catch {
            // A half-created document would be confusing; leave no empty folder behind.
            try? fileManager.removeItem(at: folderURL)
            throw error
        }
        return mainURL
    }
}
