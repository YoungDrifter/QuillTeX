import Foundation
import Combine

struct PluginOption: Identifiable {
    let id: String
    let title: String
    var defaultValue = true
    var explanation: String = ""
}

/// Built-in extensions register their lifecycle here; disabling a plugin stops its work.
@MainActor
struct AppPlugin: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    var defaultEnabled: Bool = false
    var options: [PluginOption] = []
    var introduction: String = ""
    var usage: String = ""
    let activate: () -> Void
    let deactivate: () -> Void
}

@MainActor
final class PluginManager: ObservableObject {
    // Register shipped extensions here. Core document features stay outside this list.
    static let completionID = "completion"
    static let settingsChanged = Notification.Name("QuillTeX.pluginSettingsChanged")
    static let subfilesID = "subfiles"
    static let subfilesChanged = Notification.Name("QuillTeX.subfilesChanged")
    static let shared = PluginManager(plugins: [
        AppPlugin(id: subfilesID, name: "Subfiles", summary: "Browse and arrange included TeX files.",
                  symbol: "doc.on.doc", defaultEnabled: true,
                  options: [PluginOption(id: "extensions", title: "Show file extensions", defaultValue: false, explanation: "Show the .tex suffix in the Subfiles list."),
                            PluginOption(id: "unlinked", title: "Show files not in the main file", explanation: "Include the Not in Main File group without changing file references.")],
                  introduction: "Subfiles brings the TeX files of a multi-file project into one sidebar. In Main File follows the order of input and include references; Not in Main File shows other TeX files available in the project.",
                  usage: "Click a file to edit it. Drag an existing reference to reorder it, or drag another TeX file between references or into the main source to insert it. These actions update the main document and can be undone. Disabling Subfiles removes its sidebar entry and cancels drag previews without deleting files or references.",
                  activate: { NotificationCenter.default.post(name: subfilesChanged, object: true) },
                  deactivate: { NotificationCenter.default.post(name: subfilesChanged, object: false) }),
        AppPlugin(id: completionID, name: "Completion", summary: "Complete LaTeX commands, environments and references.",
                  symbol: "text.cursor", defaultEnabled: true,
                  options: [PluginOption(id: "automatic", title: "Automatic inline hints", explanation: "Show gray suggestions as you type; turning this off keeps the manual candidate list available."),
                            PluginOption(id: "pairs", title: "Delimiter hints and paired editing", explanation: "Suggest matching brackets and math delimiters, skip existing closers, and delete empty pairs together."),
                            PluginOption(id: "environmentEnd", title: "Environment closing hints", explanation: "After a completed begin statement, offer the body and matching end for separate confirmation."),
                            PluginOption(id: "commands", title: "Commands", explanation: "Offer built-in LaTeX commands and commands declared in this project."),
                            PluginOption(id: "environments", title: "Environments", explanation: "Complete begin and end names, prioritizing project definitions and unmatched environments."),
                            PluginOption(id: "packages", title: "Packages", explanation: "Complete package names inside usepackage arguments."),
                            PluginOption(id: "classes", title: "Document classes", explanation: "Complete document class names inside documentclass arguments."),
                            PluginOption(id: "labels", title: "Labels", explanation: "Complete project label keys inside reference commands."),
                            PluginOption(id: "citations", title: "Citations", explanation: "Complete bibliography keys inside citation commands."),
                            PluginOption(id: "paths", title: "File paths", explanation: "Offer project-relative TeX files for input, include and subfile, and image files for includegraphics.")],
                  introduction: "Completion combines quiet inline hints with an on-demand candidate list. It recognizes commands, environments, packages, document classes, labels, citation keys and project-relative TeX or image paths. Definitions in the current project, including unsaved edits, take priority over bundled commands and environments.",
                  usage: "Use the shortcut below to open candidates, then keep typing to filter them. Use the arrow keys to select, Return or Tab to accept, or click a row. Esc closes the list. Tab accepts inline hints; Tab and Shift–Tab move between command arguments. A begin command, its environment name, and the matching end are accepted separately, each with its own undo step. Delimiter hints stay inline and do not appear in the list. Disabling this plugin stops completion tasks and removes its menu command, while keeping your text and settings.",
                  activate: {}, deactivate: {})
    ])
    let plugins: [AppPlugin]
    private let defaults: UserDefaults
    @Published private var enabled: [String: Bool] = [:]

    init(plugins: [AppPlugin], defaults: UserDefaults = .standard) {
        precondition(Set(plugins.map(\.id)).count == plugins.count, "Plugin IDs must be unique")
        self.plugins = plugins
        self.defaults = defaults
        for plugin in plugins {
            let active = defaults.object(forKey: Self.key(plugin.id)) as? Bool ?? plugin.defaultEnabled
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
        NotificationCenter.default.post(name: Self.settingsChanged, object: id)
    }

    func option(_ id: String, for pluginID: String) -> Bool {
        defaults.object(forKey: "plugins.\(pluginID).\(id)") as? Bool
            ?? plugins.first(where: { $0.id == pluginID })?.options.first(where: { $0.id == id })?.defaultValue ?? true
    }
    func setOption(_ value: Bool, id: String, for pluginID: String) {
        objectWillChange.send()
        defaults.set(value, forKey: "plugins.\(pluginID).\(id)")
        NotificationCenter.default.post(name: Self.settingsChanged, object: pluginID)
    }
    func stringPreference(_ name: String, for pluginID: String) -> String? {
        defaults.string(forKey: "plugins.\(pluginID).\(name)")
    }
    func setStringPreference(_ value: String?, name: String, for pluginID: String) {
        objectWillChange.send()
        defaults.set(value, forKey: "plugins.\(pluginID).\(name)")
        NotificationCenter.default.post(name: Self.settingsChanged, object: pluginID)
    }
    private static func key(_ id: String) -> String { "plugins.\(id).enabled" }
}
