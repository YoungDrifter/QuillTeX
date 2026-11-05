import SwiftUI

struct PluginSettingsPane: View {
    @ObservedObject var manager: PluginManager = .shared

    @State private var selectedID: String?

    init(initialPluginID: String? = nil) {
        _selectedID = State(initialValue: initialPluginID)
    }

    var body: some View {
        if let plugin = manager.plugins.first(where: { $0.id == selectedID }) {
            details(plugin)
        } else {
        SettingsPage(title: "Plugins", subtitle: "Manage optional features.") {
            if manager.plugins.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("No plugins yet").font(.system(size: 15, weight: .medium))

                }
                .frame(maxWidth: .infinity).padding(.vertical, 48).padding(.horizontal, 24)
                .background(SettingsStyle.secondarySurface, in: RoundedRectangle(cornerRadius: ChromeMetrics.panelCornerRadius))
            } else {
                SettingsCard(title: "Available plugins") {
                    ForEach(Array(manager.plugins.enumerated()), id: \.element.id) { index, plugin in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Image(systemName: plugin.symbol).font(.system(size: 18)).frame(width: 26)
                            SettingsRow(title: plugin.name, subtitle: plugin.summary) {
                                Button { selectedID = plugin.id } label: { Image(systemName: "gearshape") }
                                    .buttonStyle(SettingsActionStyle()).help("Settings for \(plugin.name)")
                                    .accessibilityLabel("Settings for \(plugin.name)")
                                Toggle(plugin.name, isOn: Binding(
                                    get: { manager.isEnabled(plugin.id) },
                                    set: { manager.setEnabled($0, for: plugin.id) }
                                ))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                .accessibilityLabel("Enable \(plugin.name)")
                            }
                        }
                    }
                }
            }
        }
        }
    }
    private func details(_ plugin: AppPlugin) -> some View {
        SettingsPage(title: plugin.name, subtitle: plugin.summary) {
            Button("Back to Plugins", systemImage: "chevron.left") { selectedID = nil }
                .buttonStyle(SettingsActionStyle())
            SettingsCard(title: "About this plugin") {
                Text(plugin.introduction).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                Text(plugin.usage).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
            if plugin.id == PluginManager.completionID {
                SettingsCard(title: "Keyboard shortcut") { CompletionShortcutSettings(manager: manager) }
            }
            SettingsCard(title: "Settings") {
                ForEach(plugin.options) { option in
                    SettingsRow(title: option.title, subtitle: option.explanation) {
                        Toggle(option.title, isOn: Binding(get: { manager.option(option.id, for: plugin.id) },
                            set: { manager.setOption($0, id: option.id, for: plugin.id) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            if plugin.id == PluginManager.completionID {
                Text("\(manager.completionShortcut.display) shows candidates · Tab accepts hints · Esc dismisses")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
