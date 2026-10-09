import Foundation
import Combine

/// Built-in extensions register their lifecycle here; disabling a plugin stops its work.
@MainActor
struct AppPlugin: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let activate: () -> Void
    let deactivate: () -> Void
}

@MainActor
final class PluginManager: ObservableObject {
    // Register shipped extensions here. Core document features stay outside this list.
    static let shared = PluginManager(plugins: [])
    let plugins: [AppPlugin]
    private let defaults: UserDefaults
    @Published private var enabled: [String: Bool] = [:]

    init(plugins: [AppPlugin], defaults: UserDefaults = .standard) {
        precondition(Set(plugins.map(\.id)).count == plugins.count, "Plugin IDs must be unique")
        self.plugins = plugins
        self.defaults = defaults
        for plugin in plugins {
            let active = defaults.bool(forKey: Self.key(plugin.id))
            enabled[plugin.id] = active
            if active { plugin.activate() }
        }
    }

    func isEnabled(_ id: String) -> Bool { enabled[id] ?? false }

    func setEnabled(_ active: Bool, for id: String) {
        guard let plugin = plugins.first(where: { $0.id == id }), isEnabled(id) != active else { return }
        defaults.set(active, forKey: Self.key(id))
        enabled[id] = active
        if active { plugin.activate() } else { plugin.deactivate() }
    }

    private static func key(_ id: String) -> String { "plugins.\(id).enabled" }
}
