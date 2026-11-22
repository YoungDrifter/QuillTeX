import Foundation
import Combine

/// Owns the single manual sync operation. There is deliberately no timer and no
/// automatic trigger: the only entry points are the sidebar Sync button and the
/// Sync settings page.
@MainActor
final class SyncController: ObservableObject {
    static let shared = SyncController()

    @Published private(set) var isSyncing = false
    @Published private(set) var statusMessage = "Not synced yet"
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncAt: Date?

    private let ledgerStore: SyncLedgerStore
    private var task: Task<Void, Never>?

    init() {
        ledgerStore = SyncLedgerStore(directory: DocumentCatalog.shared.directory)
        let ledger = ledgerStore.load()
        lastSyncAt = ledger.lastSyncAt
        if let date = ledger.lastSyncAt {
            statusMessage = "Last sync \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    func syncNow() {
        guard !isSyncing else { return }
        let settings = SyncSettings.shared
        settings.loadPasswordIfNeeded()

        guard let baseURL = settings.baseURL,
              let configuration = settings.makeConfiguration(),
              settings.isConfigured else {
            SettingsNavigation.shared.section = .sync
            QuillDialogCenter.shared.showAlert(
                "Sync Not Configured",
                "Enter your Nutstore WebDAV URL, account, and app password in Settings > Sync.")
            return
        }

        isSyncing = true
        lastError = nil
        statusMessage = "Preparing…"

        let client = WebDAVClient(baseURL: baseURL,
                                  username: settings.trimmedAccount,
                                  password: settings.password)
        let engine = SyncEngine(catalog: DocumentCatalog.shared,
                                ledgerStore: ledgerStore,
                                transport: client,
                                configuration: configuration,
                                outputDirectory: BuildSettings.shared.outputDirectory)

        task = Task { [weak self] in
            do {
                let summary = try await engine.run { [weak self] message in
                    self?.statusMessage = message
                }
                guard let self else { return }
                self.isSyncing = false
                self.lastError = nil
                self.lastSyncAt = Date()
                self.statusMessage = summary.message
                QuillToast.shared.show(summary.message)
            } catch {
                guard let self else { return }
                self.isSyncing = false
                self.lastError = error.localizedDescription
                self.statusMessage = "Sync failed"
                QuillDialogCenter.shared.showAlert("Sync Failed", error.localizedDescription)
            }
        }
    }
}
