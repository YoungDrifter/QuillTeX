import Foundation
import AppKit
import SwiftUI

struct CompletionOptions: Sendable {
    var automatic = true
    var pairs = true
    var environmentEnd = true
    var disabledCategories: Set<String> = []
    func allows(_ context: LaTeXCompletion.Context) -> Bool { !disabledCategories.contains(context.category) }
}

extension LaTeXCompletion.Context {
    var category: String {
        switch self {
        case .command: "commands"
        case .environment, .endEnvironment: "environments"
        case .package: "packages"
        case .documentClass: "classes"
        case .label: "labels"
        case .citation: "citations"
        case .texPath, .imagePath: "paths"
        }
    }
}

// Pure inventory provider, called off the main thread and independent of TeX Project.
enum CompletionPaths {
    static func candidates(root: URL?, images: Bool) -> [String] {
        guard let root else { return [] }
        let directory = root.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var results: [String] = []
        let extensions: Set<String> = images ? ["pdf", "png", "jpg", "jpeg", "eps"] : ["tex"]
        for case let url as URL in walker {
            if Task.isCancelled { return [] }
            if ["build", "release", "node_modules"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(directory.path + "/"), extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            results.append(String(path.dropFirst(directory.path.count + 1)))
        }
        return results.sorted()
    }
}

extension PluginManager {
    var completionOptions: CompletionOptions {
        let id = Self.completionID
        return CompletionOptions(automatic: option("automatic", for: id), pairs: option("pairs", for: id),
            environmentEnd: option("environmentEnd", for: id),
            disabledCategories: Set(["commands", "environments", "packages", "classes", "labels", "citations", "paths"].filter { !option($0, for: id) }))
    }

}

struct CompletionShortcut: Codable, Equatable {
    var key: String
    var modifiers: UInt
    static let standard = CompletionShortcut(key: "\u{1b}", modifiers: NSEvent.ModifierFlags.option.rawValue)
    var eventModifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var swiftModifiers: EventModifiers {
        var result: EventModifiers = []
        if eventModifiers.contains(.command) { result.insert(.command) }
        if eventModifiers.contains(.control) { result.insert(.control) }
        if eventModifiers.contains(.option) { result.insert(.option) }
        if eventModifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
    var equivalent: KeyEquivalent { KeyEquivalent(key.first ?? "\u{1b}") }
    var display: String {
        let flags = eventModifiers
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") +
            (key == "\u{1b}" ? "Esc" : key == " " ? "Space" : key.uppercased())
    }
    var isValid: Bool {
        key.count == 1 && !eventModifiers.intersection([.command, .control, .option]).isEmpty &&
            !["\t", "\r", "\u{7f}"].contains(key)
    }
    init(key: String, modifiers: UInt) { self.key = key; self.modifiers = modifiers }
    init?(event: NSEvent) {
        guard let key = event.characters(byApplyingModifiers: [])?.lowercased(), key.count == 1 else { return nil }
        self.init(key: key, modifiers: event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue)
        guard isValid else { return nil }
    }
    func matches(_ event: NSEvent) -> Bool { CompletionShortcut(event: event) == self }
    @MainActor func conflict(in menu: NSMenu?) -> String? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title != "Show Completions", item.keyEquivalent.lowercased() == key,
               item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift]) == eventModifiers { return item.title }
            if let conflict = conflict(in: item.submenu) { return conflict }
        }
        return nil
    }
}

extension PluginManager {
    var completionShortcut: CompletionShortcut {
        guard let value = stringPreference("shortcut", for: Self.completionID), let data = value.data(using: .utf8),
              let shortcut = try? JSONDecoder().decode(CompletionShortcut.self, from: data), shortcut.isValid else { return .standard }
        return shortcut
    }
    func setCompletionShortcut(_ shortcut: CompletionShortcut) {
        guard shortcut.isValid, let data = try? JSONEncoder().encode(shortcut) else { return }
        setStringPreference(String(data: data, encoding: .utf8), name: "shortcut", for: Self.completionID)
    }
}
