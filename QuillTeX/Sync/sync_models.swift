import Foundation
import CryptoKit

/// One logical library folder in the published snapshot. The receiver rebuilds
/// the tree from `parentID`; `name` is never joined into a physical path because
/// library folder names may contain characters that are illegal in a path.
struct SyncFolderRecord: Codable, Equatable {
    var id: String
    var parentID: String?
    var name: String
    var color: String?
    var sortOrder: String?
}

/// The immutable PDF blob a project points at. `blob` is relative to
/// `v1/index.json`, for example `blobs/<sha256>.pdf`.
struct SyncPDFRecord: Codable, Equatable {
    var blob: String
    var sha256: String
    var bytes: Int
}

/// One document-library entry. Absolute local paths are deliberately absent:
/// the receiving app never needs the sender's home directory.
struct SyncProjectRecord: Codable, Equatable {
    var id: String
    var displayName: String
    var mainFileName: String
    var kind: String
    var folderID: String?
    var folderPath: [String]
    var tags: [String]
    var starred: Bool
    var addedAt: Date?
    var lastViewedAt: Date?
    var updatedAt: Date?
    var createdOnDiskAt: Date?
    var pdf: SyncPDFRecord?
}

/// The stable part of the index. Its encoding is hashed to decide whether the
/// remote index needs a new upload; `revision` and `generatedAt` are excluded so
/// an unchanged library does not look different on every sync.
struct SyncIndexContent: Codable, Equatable {
    var schemaVersion: Int = 1
    var appVersion: String
    var folders: [SyncFolderRecord]
    var projects: [SyncProjectRecord]
}

/// The document actually written to `v1/index.json`.
struct SyncIndex: Codable, Equatable {
    var schemaVersion: Int
    var revision: Int
    var generatedAt: Date
    var appVersion: String
    var folders: [SyncFolderRecord]
    var projects: [SyncProjectRecord]
}

/// File facts used to avoid re-hashing an unchanged PDF on every click. The
/// modification date is a double because file systems expose sub-second values.
struct SyncPDFStamp: Codable, Equatable {
    var bytes: Int
    var modified: Double
    var hash: String
}

/// Local bookkeeping, stored beside DocumentCatalog.json. It is not uploaded and
/// may be deleted at any time; the next sync then rebuilds it.
struct SyncLedger: Codable, Equatable {
    var version: Int = 1
    var schemaVersion: Int = 1
    var indexFingerprint: String?
    var revision: Int = 0
    var uploadedBlobs: [String] = []
    var pdfStamps: [String: SyncPDFStamp] = [:]
    var lastSyncAt: Date?
}

struct SyncConfiguration: Equatable {
    /// Path below the WebDAV root, for example ["QuillTeX"].
    var remotePath: [String]
    var appVersion: String

    static func currentAppVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

enum SyncEncoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    static func fingerprint(_ content: SyncIndexContent) throws -> String {
        try encoded(content).sha256Hex
    }
}

extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

enum FileDigest {
    /// Stream a file through SHA-256 so a large PDF is never loaded into memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads and writes the local incremental state atomically.
final class SyncLedgerStore {
    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("SyncState.json")
    }

    func load() -> SyncLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? SyncEncoding.decoder().decode(SyncLedger.self, from: data) else {
            return SyncLedger()
        }
        return ledger
    }

    func save(_ ledger: SyncLedger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SyncEncoding.encoded(ledger).write(to: url, options: .atomic)
    }
}

/// Builds the portable part of the snapshot from the live document library and
/// the same PDF resolver the library UI uses.
@MainActor
enum SyncSnapshotBuilder {
    struct Snapshot {
        var folders: [SyncFolderRecord]
        var projects: [SyncProjectRecord]
        /// Entry UUID string -> compiled PDF on this Mac.
        var pdfURLs: [String: URL]
    }

    static func build(catalog: DocumentCatalog, outputDirectory: String) -> Snapshot {
        let folders = catalog.foldersInTreeOrder().map { item in
            SyncFolderRecord(id: item.folder.id.uuidString,
                             parentID: item.folder.parentID?.uuidString,
                             name: item.folder.name,
                             color: item.folder.color?.rawValue,
                             sortOrder: item.folder.sortOrder?.rawValue)
        }

        var folderByID: [UUID: LibraryFolder] = [:]
        for folder in catalog.folders { folderByID[folder.id] = folder }

        func folderPath(for id: UUID?) -> [String] {
            var result: [String] = []
            var current = id
            var seen = Set<UUID>()
            while let currentID = current,
                  seen.insert(currentID).inserted,
                  let folder = folderByID[currentID] {
                result.insert(folder.name, at: 0)
                current = folder.parentID
            }
            return result
        }

        let entries = catalog.entries.sorted { $0.id.uuidString < $1.id.uuidString }
        var projects: [SyncProjectRecord] = []
        var pdfURLs: [String: URL] = [:]
        for entry in entries {
            let id = entry.id.uuidString
            if let pdf = LibraryPDFLocator.pdfURL(for: entry, outputDirectory: outputDirectory) {
                pdfURLs[id] = pdf.standardizedFileURL
            }
            projects.append(SyncProjectRecord(
                id: id,
                displayName: entry.displayName,
                mainFileName: entry.url.lastPathComponent,
                kind: entry.kind.rawValue,
                folderID: entry.folderID?.uuidString,
                folderPath: folderPath(for: entry.folderID),
                tags: entry.tags,
                starred: entry.starred,
                addedAt: entry.addedAt,
                lastViewedAt: entry.lastViewedAt,
                updatedAt: entry.updatedAt,
                createdOnDiskAt: entry.createdOnDiskAt,
                pdf: nil))
        }

        return Snapshot(folders: folders, projects: projects, pdfURLs: pdfURLs)
    }
}
