import Foundation
import Combine
import Security

/// The app password is the only secret; the server, account and remote folder
/// are ordinary preferences. Keeping the password in the Keychain avoids
/// writing it into UserDefaults or the sync ledger.
enum SyncCredentialStore {
    private static let service = "is.quilltex.webdav"
    private static let account = "app-password"

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw keychainError(status)
        }
        return password
    }

    static func save(_ password: String) throws {
        guard !password.isEmpty else {
            try delete()
            return
        }
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw keychainError(updateStatus)
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class SyncSettings: ObservableObject {
    static let shared = SyncSettings()
    static let defaultServer = "https://dav.jianguoyun.com/dav/"
    static let defaultRemoteFolder = "QuillTeX"

    private enum Keys {
        static let server = "sync.webdav.server"
        static let account = "sync.webdav.account"
        static let remoteFolder = "sync.webdav.remoteFolder"
    }

    private let defaults: UserDefaults
    @Published var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Keys.server) }
    }
    @Published var account: String {
        didSet { defaults.set(account, forKey: Keys.account) }
    }
    @Published var remoteFolder: String {
        didSet { defaults.set(remoteFolder, forKey: Keys.remoteFolder) }
    }
    @Published var password: String = "" {
        didSet {
            guard !suppressPasswordSave, password != oldValue else { return }
            passwordDirty = true
            schedulePasswordSave()
        }
    }
    @Published private(set) var credentialError: String?

    private var passwordLoaded = false
    private var passwordDirty = false
    private var suppressPasswordSave = false
    private var passwordSaveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverURL = defaults.string(forKey: Keys.server) ?? Self.defaultServer
        account = defaults.string(forKey: Keys.account) ?? ""
        remoteFolder = defaults.string(forKey: Keys.remoteFolder) ?? Self.defaultRemoteFolder
    }

    var trimmedAccount: String {
        account.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var baseURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Library folder names may contain "/", so the remote folder is still
    /// handled as path components rather than a single path string.
    var remotePathComponents: [String]? {
        let parts = remoteFolder.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return parts.isEmpty ? [Self.defaultRemoteFolder] : parts
    }

    var isConfigured: Bool {
        baseURL != nil && !trimmedAccount.isEmpty && !password.isEmpty && remotePathComponents != nil
    }

    func makeConfiguration() -> SyncConfiguration? {
        guard let remotePath = remotePathComponents else { return nil }
        return SyncConfiguration(remotePath: remotePath,
                                 appVersion: SyncConfiguration.currentAppVersion())
    }

    /// Keychain access is delayed until Sync is opened or used, so launching the
    /// app does not prompt for credentials the user never configured.
    func loadPasswordIfNeeded() {
        guard !passwordLoaded else { return }
        passwordLoaded = true
        do {
            if let stored = try SyncCredentialStore.load(), password.isEmpty {
                suppressPasswordSave = true
                password = stored
                suppressPasswordSave = false
                passwordDirty = false
            }
            credentialError = nil
        } catch {
            credentialError = error.localizedDescription
        }
    }

    func flushPassword() {
        guard passwordDirty else { return }
        passwordSaveTask?.cancel()
        do {
            try SyncCredentialStore.save(password)
            passwordDirty = false
            credentialError = nil
        } catch {
            credentialError = error.localizedDescription
        }
    }

    private func schedulePasswordSave() {
        passwordSaveTask?.cancel()
        let value = password
        passwordSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try SyncCredentialStore.save(value)
                if self?.password == value { self?.passwordDirty = false }
                self?.credentialError = nil
            } catch {
                self?.credentialError = error.localizedDescription
            }
        }
    }
}
