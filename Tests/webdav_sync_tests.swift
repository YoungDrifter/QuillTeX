import Foundation
import CryptoKit

private final class MockWebDAVTransport: WebDAVTransport {
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    var putCount = 0

    private func key(_ components: [String]) -> String {
        components.joined(separator: "/")
    }

    func testConnection() async throws {}

    func ensureDirectory(_ components: [String]) async throws {
        directories.insert(key(components))
    }

    func exists(_ components: [String]) async throws -> Bool {
        files[key(components)] != nil || directories.contains(key(components))
    }

    func put(_ data: Data, at components: [String], contentType: String) async throws {
        putCount += 1
        files[key(components)] = data
    }

    func put(fileAt url: URL, at components: [String], contentType: String) async throws {
        putCount += 1
        files[key(components)] = try Data(contentsOf: url)
    }

    func delete(_ components: [String]) async throws {
        files.removeValue(forKey: key(components))
    }
}

@main
struct WebDAVSyncTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("QuillTeX-webdav-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let dataDirectory = base.appendingPathComponent("data", isDirectory: true)
        let catalog = DocumentCatalog(directory: dataDirectory)

        let projectDirectory = base.appendingPathComponent("Papers/Alpha", isDirectory: true)
        try fm.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let mainURL = projectDirectory.appendingPathComponent("main.tex")
        let pdfURL = projectDirectory.appendingPathComponent("main.pdf")
        try "\\documentclass{article}".write(to: mainURL, atomically: true, encoding: .utf8)
        try Data("%PDF-1.4\nfirst".utf8).write(to: pdfURL)

        let entry = try catalog.link(mainURL)
        let research = try catalog.createFolder(named: "Research")
        catalog.setFolder(entry.id, folderID: research.id)

        // MARK: - Snapshot

        let snapshot = SyncSnapshotBuilder.build(catalog: catalog, outputDirectory: ".")
        check(snapshot.folders.count == 1, "snapshot includes library folders")
        check(snapshot.projects.count == 1, "snapshot includes library documents")
        check(snapshot.projects[0].id == entry.id.uuidString, "snapshot uses the stable library id")
        check(snapshot.projects[0].folderPath == ["Research"], "snapshot resolves the folder path")
        check(snapshot.projects[0].mainFileName == "main.tex", "snapshot records only the main file name")
        check(snapshot.pdfURLs[entry.id.uuidString] == pdfURL.standardizedFileURL,
              "snapshot resolves the compiled PDF beside the source")

        // MARK: - Hashing and deterministic index

        check(Data("abc".utf8).sha256Hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
              "SHA-256 helper matches the known digest")

        var content = SyncIndexContent(appVersion: "test", folders: snapshot.folders, projects: snapshot.projects)
        let firstFingerprint = try SyncEncoding.fingerprint(content)
        let repeatedFingerprint = try SyncEncoding.fingerprint(content)
        check(firstFingerprint == repeatedFingerprint,
              "index fingerprint is deterministic")
        content.projects[0].displayName = "Renamed"
        let renamedFingerprint = try SyncEncoding.fingerprint(content)
        check(firstFingerprint != renamedFingerprint,
              "a metadata change changes the index fingerprint")
        content.projects[0].displayName = "Alpha"

        // MARK: - Ledger round trip

        let store = SyncLedgerStore(directory: dataDirectory)
        var seed = SyncLedger()
        seed.indexFingerprint = firstFingerprint
        seed.revision = 3
        seed.uploadedBlobs = ["abc"]
        seed.lastSyncAt = Date(timeIntervalSince1970: 100)
        try store.save(seed)
        check(store.load().indexFingerprint == firstFingerprint, "ledger persists its fingerprint")
        check(store.load().revision == 3, "ledger persists its revision")
        check(store.load().lastSyncAt == Date(timeIntervalSince1970: 100), "ledger persists the last sync date")

        // Reset so the engine starts from a clean state.
        try store.save(SyncLedger())

        // MARK: - Incremental publish

        let transport = MockWebDAVTransport()
        let configuration = SyncConfiguration(remotePath: ["QuillTeX"], appVersion: "test")
        let engine = SyncEngine(catalog: catalog,
                                ledgerStore: store,
                                transport: transport,
                                configuration: configuration,
                                outputDirectory: ".")

        let first = try await engine.run()
        check(first.uploadedPDFs == 1, "first sync uploads the PDF")
        check(first.uploadedIndex, "first sync uploads the index")
        check(first.projectCount == 1 && first.missingPDFs == 0, "first sync reports one complete project")
        check(transport.files["QuillTeX/v1/index.json"] != nil, "index is written below the remote folder")
        check(transport.files.keys.contains { $0.hasPrefix("QuillTeX/v1/blobs/") && $0.hasSuffix(".pdf") },
              "PDF is written as a content-addressed blob")
        let firstBlobKey = try XCTUnwrap(transport.files.keys.first {
            $0.hasPrefix("QuillTeX/v1/blobs/") && $0.hasSuffix(".pdf")
        })
        let afterFirstPutCount = transport.putCount

        let second = try await engine.run()
        check(second.uploadedPDFs == 0, "an unchanged sync does not re-upload the PDF")
        check(!second.uploadedIndex, "an unchanged sync does not re-upload the index")
        check(transport.putCount == afterFirstPutCount, "an unchanged sync performs no PUT")

        catalog.touch(entry.id)
        let touched = try await engine.run()
        check(touched.uploadedPDFs == 0, "opening a document does not re-upload its PDF")
        check(!touched.uploadedIndex, "a last-viewed change alone does not re-upload the index")
        check(transport.putCount == afterFirstPutCount, "a last-viewed change performs no PUT")

        let archive = try catalog.createFolder(named: "Archive")
        catalog.setFolder(entry.id, folderID: archive.id)
        let third = try await engine.run()
        check(third.uploadedPDFs == 0, "a folder move does not re-upload the PDF")
        check(third.uploadedIndex, "a folder move updates the index")
        check(transport.putCount == afterFirstPutCount + 1, "a folder move performs exactly one PUT")

        try Data("%PDF-1.4\nsecond".utf8).write(to: pdfURL)
        let fourth = try await engine.run()
        check(fourth.uploadedPDFs == 1, "a changed PDF is uploaded")
        check(fourth.uploadedIndex, "a changed PDF updates the index")
        check(transport.files[firstBlobKey] == nil, "the previous PDF blob is removed after the index update")

        let indexData = try XCTUnwrap(transport.files["QuillTeX/v1/index.json"])
        let index = try SyncEncoding.decoder().decode(SyncIndex.self, from: indexData)
        check(index.schemaVersion == 1, "index carries a schema version")
        check(index.projects.count == 1, "index carries the current project")
        check(index.projects[0].folderPath == ["Archive"], "index carries the updated folder path")
        check(index.projects[0].pdf != nil, "index points at the PDF blob")
        let body = String(decoding: indexData, as: UTF8.self)
        check(!body.contains(base.path), "index does not leak the local absolute path")

        try fm.removeItem(at: pdfURL)
        let fifth = try await engine.run()
        check(fifth.uploadedPDFs == 0, "a missing PDF is not uploaded")
        check(fifth.uploadedIndex, "a missing PDF changes the index")
        check(fifth.missingPDFs == 1, "a missing PDF is counted")

        let finalData = try XCTUnwrap(transport.files["QuillTeX/v1/index.json"])
        let finalIndex = try SyncEncoding.decoder().decode(SyncIndex.self, from: finalData)
        check(finalIndex.projects[0].pdf == nil, "a missing PDF becomes null in the index")

        print("PASS: \(checks) webdav-sync assertions")
    }

    private static func XCTUnwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "WebDAVSyncTests", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "missing value"]) }
        return value
    }
}
