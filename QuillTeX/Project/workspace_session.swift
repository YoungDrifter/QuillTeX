import Foundation
import CryptoKit

/// Writing state and recoverable drafts live in Application Support, apart from sources.
struct WorkspaceSession: Codable {
    struct Document: Codable {
        var path: String
        var selectionLocation: Int
        var selectionLength: Int
        var scrollX: Double
        var scrollY: Double
        var draft: String?
        var savedText: String?
        var diskText: String?
    }
    var version = 1
    var rootPath: String
    var documents: [Document]
    var activePath: String?
    var sidebarVisible: Bool
    var sidebarMode: String
    var paneMode: Int
    var tabBarVisible: Bool?
    var expandedNodes: [String]
    var sidebarWidth: Double
    var editorFraction: Double
    var pdf: PDFReadingState?
    var pdfIsOutdated: Bool? = nil
    var sourceDirectoryPath: String? = nil
}

/// A serial writer keeps a slow draft write from replacing a newer workspace state.
final class WorkspaceSessionStore: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "is.quilltex.workspace-session", qos: .utility)
    init(directory: URL) { self.directory = directory }
    private func file(for root: URL) -> URL {
        let key = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    func load(root: URL) -> WorkspaceSession? {
        queue.sync {
            guard let data = try? Data(contentsOf: file(for: root)),
                  let state = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
                  state.version == 1, state.rootPath == root.standardizedFileURL.path else { return nil }
            return state
        }
    }
    func save(_ state: WorkspaceSession, retiringRoots: [URL] = [], completion: (@Sendable (String?) -> Void)? = nil) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(state)
                try data.write(to: file(for: URL(fileURLWithPath: state.rootPath)), options: .atomic)
                try Data(state.rootPath.utf8).write(to: directory.appendingPathComponent("LastWorkspace"), options: .atomic)
                for root in retiringRoots where root.path != state.rootPath {
                    let oldFile = file(for: root)
                    guard let previous = try? Data(contentsOf: oldFile),
                          var old = try? JSONDecoder().decode(WorkspaceSession.self, from: previous) else { continue }
                    for index in old.documents.indices {
                        old.documents[index].draft = nil
                        old.documents[index].savedText = nil
                        old.documents[index].diskText = nil
                    }
                    try JSONEncoder().encode(old).write(to: oldFile, options: .atomic)
                }
                completion?(nil)
            } catch { completion?(error.localizedDescription) }
        }
    }
    func flush() { queue.sync {} }
    func lastWorkspace() -> URL? {
        queue.sync {
            guard let path = try? String(contentsOf: directory.appendingPathComponent("LastWorkspace"), encoding: .utf8),
                  !path.isEmpty else { return nil }
            let root = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) { return root }
            guard let data = try? Data(contentsOf: file(for: root)),
                  let state = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
                  state.version == 1, state.rootPath == path,
                  state.documents.contains(where: { $0.path == path && $0.draft != nil }) else { return nil }
            return root
        }
    }
}
