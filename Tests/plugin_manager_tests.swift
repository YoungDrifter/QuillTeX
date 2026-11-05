import Foundation
import AppKit

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
        let shipped = AppPlugin(id: "subfiles", name: "Subfiles", summary: "", symbol: "doc.on.doc", defaultEnabled: true,
                                activate: { starts += 1 }, deactivate: { stops += 1 })
        let shippedManager = PluginManager(plugins: [shipped], defaults: defaults)
        precondition(shippedManager.isEnabled("subfiles"))
        shippedManager.setEnabled(false, for: "subfiles")
        precondition(!PluginManager(plugins: [shipped], defaults: defaults).isEnabled("subfiles"))
        let configurable = AppPlugin(id: "configured", name: "Configured", summary: "", symbol: "gearshape",
            options: [PluginOption(id: "details", title: "Details", defaultValue: false)], activate: {}, deactivate: {})
        let options = PluginManager(plugins: [configurable], defaults: defaults)
        precondition(!options.option("details", for: "configured"))
        options.setOption(true, id: "details", for: "configured")
        precondition(!options.isEnabled("configured"))
        precondition(PluginManager(plugins: [configurable], defaults: defaults).option("details", for: "configured"))
        let custom = CompletionShortcut(key: "j", modifiers: NSEvent.ModifierFlags.control.union(.option).rawValue)
        options.setCompletionShortcut(custom)
        precondition(PluginManager(plugins: [configurable], defaults: defaults).completionShortcut == custom)
        precondition(custom.display == "⌃⌥J")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
            windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38)!
        precondition(custom.matches(event))
        precondition(!CompletionShortcut(key: "j", modifiers: 0).isValid)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Existing Action", action: nil, keyEquivalent: "j")
        item.keyEquivalentModifierMask = [.control, .option]; menu.addItem(item)
        precondition(custom.conflict(in: menu) == "Existing Action")
        options.setCompletionShortcut(.standard)
        precondition(options.completionShortcut == .standard)
        options.setStringPreference("invalid", name: "shortcut", for: PluginManager.completionID)
        precondition(options.completionShortcut == .standard)
        print("PluginManager: persistence, launch activation, stop, idempotence, independence and retained data passed")
    }
}
