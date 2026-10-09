import AppKit
import Combine
import Sparkle

/// Core app maintenance, independent of optional document plugins.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupError: String?
    @Published private(set) var latestVersion = UserDefaults.standard.string(forKey: "updates.latestVerifiedVersion")
    private var observation: AnyCancellable?
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false,
        updaterDelegate: self, userDriverDelegate: self)

    func start() {
        guard !started else { return }
        // Hosted tests exercise their own isolated update state, without scheduling dialogs.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        do {
            try controller.updater.start()
            started = true
            // Automatic checks are mandatory; migrate any old opt-out preference.
            if !controller.updater.automaticallyChecksForUpdates {
                controller.updater.automaticallyChecksForUpdates = true
            }
            if controller.updater.updateCheckInterval != 86400 {
                controller.updater.updateCheckInterval = 86400
            }
            let lastCheck = controller.updater.lastUpdateCheckDate
            if lastCheck == nil || Date().timeIntervalSince(lastCheck!) >= 86400 {
                controller.updater.checkForUpdatesInBackground()
            } else if latestVersion == nil {
                // Bootstrap the display once after upgrading from a build without this cache.
                controller.updater.checkForUpdateInformation()
            }
            observation = controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }
        } catch {
            startupError = "Restart to enable updates."
        }
    }

    func checkForUpdates() {
        start()
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // The core update policy shows new releases as soon as the daily check finds them.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                  forUpdate update: SUAppcastItem,
                                                  state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        // Focus the existing verified update; this does not make another network check.
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        // This callback receives the signed feed after Sparkle verifies it.
        guard let latest = appcast.items.max(by: {
            $0.versionString.compare($1.versionString, options: .numeric) == .orderedAscending
        }) else { return }
        latestVersion = latest.displayVersionString
        UserDefaults.standard.set(latest.displayVersionString, forKey: "updates.latestVerifiedVersion")
    }
}
