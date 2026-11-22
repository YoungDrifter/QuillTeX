import Foundation

struct SyncSummary: Equatable {
    var uploadedPDFs: Int
    var uploadedIndex: Bool
    var projectCount: Int
    var missingPDFs: Int
    var revision: Int

    var message: String {
        if uploadedPDFs == 0 && !uploadedIndex {
            return missingPDFs > 0 ? "Already up to date · \(missingPDFs) without PDF" : "Already up to date"
        }
        var parts: [String] = []
        if uploadedPDFs > 0 {
            parts.append("\(uploadedPDFs) PDF\(uploadedPDFs == 1 ? "" : "s")")
        }
        if uploadedIndex {
            parts.append("library data")
        }
        var text = "Synced " + parts.joined(separator: " and ")
        if missingPDFs > 0 {
            text += " · \(missingPDFs) without PDF"
        }
        return text
    }
}

private struct StagedPDF: Sendable {
    var url: URL
    var hash: String
    var bytes: Int
    var modified: Double
}

/// One-way publisher: local library → WebDAV `index.json` + immutable PDF blobs.
/// It never downloads or merges remote content. The only remote read is an
/// existence check for the index so a manually deleted/missing remote copy can
/// be republished on the next click.
@MainActor
final class SyncEngine {
    private let catalog: DocumentCatalog
    private let ledgerStore: SyncLedgerStore
    private let transport: WebDAVTransport
    private let configuration: SyncConfiguration
    private let outputDirectory: String
    private var ledger: SyncLedger
    private var directoriesReady = false

    init(catalog: DocumentCatalog,
         ledgerStore: SyncLedgerStore,
         transport: WebDAVTransport,
         configuration: SyncConfiguration,
         outputDirectory: String) {
        self.catalog = catalog
        self.ledgerStore = ledgerStore
        self.transport = transport
        self.configuration = configuration
        self.outputDirectory = outputDirectory
        self.ledger = ledgerStore.load()
    }

    func run(progress: (String) -> Void = { _ in }) async throws -> SyncSummary {
        let v1 = configuration.remotePath + ["v1"]
        let blobs = v1 + ["blobs"]
        directoriesReady = false

        progress("Preparing library…")
        let snapshot = SyncSnapshotBuilder.build(catalog: catalog, outputDirectory: outputDirectory)
        var projects = snapshot.projects
        var uploadedPDFs = 0
        var missingPDFs = 0

        for index in projects.indices {
            let project = projects[index]
            guard let pdfURL = snapshot.pdfURLs[project.id] else {
                ledger.pdfStamps.removeValue(forKey: project.id)
                missingPDFs += 1
                continue
            }
            let result = try await uploadPDF(project: project, pdfURL: pdfURL,
                                             v1: v1, blobs: blobs, progress: progress)
            projects[index].pdf = result.record
            uploadedPDFs += result.uploaded
        }

        let content = SyncIndexContent(appVersion: configuration.appVersion,
                                       folders: snapshot.folders,
                                       projects: projects)
        // "Last viewed" changes whenever a document is opened. It is useful
        // metadata but must not make the whole index look new on every sync.
        let fingerprint = try SyncEncoding.fingerprint(Self.fingerprintContent(content))
        var needsIndex = fingerprint != ledger.indexFingerprint
        if !needsIndex {
            // Do not read the remote index, only check that it still exists.
            let exists = try await transport.exists(v1 + ["index.json"])
            needsIndex = !exists
        }

        var uploadedIndex = false
        var revision = max(1, ledger.revision)
        if needsIndex {
            try await prepareDirectories(v1: v1, blobs: blobs)
            progress("Updating library…")
            revision = max(1, ledger.revision + 1)
            let index = SyncIndex(schemaVersion: 1,
                                  revision: revision,
                                  generatedAt: Date(),
                                  appVersion: content.appVersion,
                                  folders: content.folders,
                                  projects: content.projects)
            let data = try SyncEncoding.encoded(index)
            try await transport.put(data, at: v1 + ["index.json"], contentType: "application/json")
            ledger.indexFingerprint = fingerprint
            ledger.revision = revision
            uploadedIndex = true
        }

        // The remote index is now the current snapshot, so content-addressed
        // blobs from older PDF versions can be removed. This keeps the Nutstore
        // folder at one PDF per project instead of accumulating every compile.
        // A failed deletion stays in the ledger and is retried next time.
        let referenced = Set(projects.compactMap { $0.pdf?.sha256 })
        let obsolete = Set(ledger.uploadedBlobs).subtracting(referenced)
        var failedDeletions = Set<String>()
        if !obsolete.isEmpty {
            progress("Cleaning up…")
            for hash in obsolete {
                do {
                    try await transport.delete(blobs + ["\(hash).pdf"])
                } catch {
                    failedDeletions.insert(hash)
                }
            }
        }
        ledger.uploadedBlobs = Array(Set(ledger.uploadedBlobs)
            .filter { referenced.contains($0) || failedDeletions.contains($0) })
            .sorted()
        ledger.pdfStamps = ledger.pdfStamps.filter { referenced.contains($0.value.hash) }
        ledger.lastSyncAt = Date()
        try? ledgerStore.save(ledger)

        return SyncSummary(uploadedPDFs: uploadedPDFs,
                           uploadedIndex: uploadedIndex,
                           projectCount: projects.count,
                           missingPDFs: missingPDFs,
                           revision: revision)
    }

    // MARK: - PDFs

    private func uploadPDF(project: SyncProjectRecord,
                           pdfURL: URL,
                           v1: [String],
                           blobs: [String],
                           progress: (String) -> Void) async throws -> (record: SyncPDFRecord, uploaded: Int) {
        var staged: StagedPDF?
        defer {
            if let staged { try? FileManager.default.removeItem(at: staged.url) }
        }

        let stamp = Self.fileStamp(for: pdfURL)
        var hash: String
        if let existing = ledger.pdfStamps[project.id],
           let stamp,
           existing.bytes == stamp.bytes,
           abs(existing.modified - stamp.modified) < 0.001,
           ledger.uploadedBlobs.contains(existing.hash) {
            hash = existing.hash
        } else {
            progress("Reading \(project.displayName)…")
            let copy = try await Self.stage(pdfURL)
            staged = copy
            hash = copy.hash
            ledger.pdfStamps[project.id] = SyncPDFStamp(bytes: copy.bytes, modified: copy.modified, hash: copy.hash)
            try? ledgerStore.save(ledger)
        }

        var uploaded = 0
        if !ledger.uploadedBlobs.contains(hash) {
            if staged == nil {
                let copy = try await Self.stage(pdfURL)
                staged = copy
                hash = copy.hash
                ledger.pdfStamps[project.id] = SyncPDFStamp(bytes: copy.bytes, modified: copy.modified, hash: copy.hash)
                try? ledgerStore.save(ledger)
            }
            try await prepareDirectories(v1: v1, blobs: blobs)
            progress("Uploading \(project.displayName)…")
            try await transport.put(fileAt: staged!.url,
                                    at: blobs + ["\(hash).pdf"],
                                    contentType: "application/pdf")
            ledger.uploadedBlobs.append(hash)
            try? ledgerStore.save(ledger)
            uploaded = 1
        }

        let bytes = staged?.bytes ?? stamp?.bytes ?? 0
        return (SyncPDFRecord(blob: "blobs/\(hash).pdf", sha256: hash, bytes: bytes), uploaded)
    }

    private func prepareDirectories(v1: [String], blobs: [String]) async throws {
        guard !directoriesReady else { return }
        try await transport.ensureDirectory(v1)
        try await transport.ensureDirectory(blobs)
        directoriesReady = true
    }

    private nonisolated static func fingerprintContent(_ content: SyncIndexContent) -> SyncIndexContent {
        var copy = content
        for index in copy.projects.indices {
            copy.projects[index].lastViewedAt = nil
        }
        return copy
    }

    private nonisolated static func fileStamp(for url: URL) -> (bytes: Int, modified: Double)? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let bytes = values.fileSize,
              let date = values.contentModificationDate else { return nil }
        return (bytes, date.timeIntervalSince1970)
    }

    /// Copy first, then hash and upload the copy. A concurrent AUTO compile can
    /// replace the PDF at any moment; the uploaded bytes must match the hash in
    /// the index.
    private nonisolated static func stage(_ url: URL) async throws -> StagedPDF {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let bytes = values?.fileSize ?? 0
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

        return try await Task.detached(priority: .utility) {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuillTeX-sync-\(UUID().uuidString).pdf")
            do {
                try FileManager.default.copyItem(at: url, to: temp)
                let hash = try FileDigest.sha256(of: temp)
                return StagedPDF(url: temp, hash: hash, bytes: bytes, modified: modified)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        }.value
    }
}
