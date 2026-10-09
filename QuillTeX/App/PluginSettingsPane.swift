import SwiftUI

struct PluginSettingsPane: View {
    @ObservedObject var manager: PluginManager = .shared

    var body: some View {
        SettingsPage(title: "Plugins", subtitle: "Manage optional features.") {
            if manager.plugins.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("No plugins yet").font(.system(size: 15, weight: .medium))

                }
                .frame(maxWidth: .infinity).padding(.vertical, 48).padding(.horizontal, 24)
                .background(SettingsStyle.secondarySurface, in: RoundedRectangle(cornerRadius: 12))
            } else {
                SettingsCard(title: "Available plugins") {
                    ForEach(Array(manager.plugins.enumerated()), id: \.element.id) { index, plugin in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Image(systemName: plugin.symbol).font(.system(size: 18)).frame(width: 26)
                            SettingsRow(title: plugin.name, subtitle: plugin.summary) {
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
