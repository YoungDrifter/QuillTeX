import Foundation

@main
@MainActor
struct PluginManagerTests {
    static func main() throws {
        let suite = "PluginManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var starts = 0
        var stops = 0
        var otherStarts = 0
        let plugin = AppPlugin(id: "sample", name: "Sample", summary: "Test extension", symbol: "sparkles",
                               activate: { starts += 1 }, deactivate: { stops += 1 })
        let other = AppPlugin(id: "other", name: "Other", summary: "Independent extension", symbol: "puzzlepiece.extension",
                              activate: { otherStarts += 1 }, deactivate: {})
        let manager = PluginManager(plugins: [plugin, other], defaults: defaults)
        precondition(!manager.isEnabled("sample") && starts == 0)
        manager.setEnabled(true, for: "sample")
        manager.setEnabled(true, for: "sample")
        precondition(manager.isEnabled("sample") && starts == 1 && stops == 0)
        precondition(!manager.isEnabled("other") && otherStarts == 0)
        let reloaded = PluginManager(plugins: [plugin, other], defaults: defaults)
        precondition(reloaded.isEnabled("sample") && starts == 2)
        reloaded.setEnabled(false, for: "sample")
        reloaded.setEnabled(false, for: "sample")
        precondition(!reloaded.isEnabled("sample") && stops == 1)
        defaults.set("retained user data", forKey: "sample.document")
        let disabled = PluginManager(plugins: [plugin, other], defaults: defaults)
        precondition(!disabled.isEnabled("sample") && starts == 2)
        disabled.setEnabled(true, for: "unknown")
        precondition(!disabled.isEnabled("unknown") && defaults.object(forKey: "plugins.unknown.enabled") == nil)
        precondition(defaults.string(forKey: "sample.document") == "retained user data")
        precondition(PluginManager(plugins: [], defaults: defaults).plugins.isEmpty)
        print("PluginManager: persistence, launch activation, stop, idempotence, independence and retained data passed")
    }
}
