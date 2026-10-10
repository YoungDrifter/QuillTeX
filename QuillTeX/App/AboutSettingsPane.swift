import AppKit
import SwiftUI

struct AboutSettingsPane: View {
    let appName: String
    let icon: NSImage
    let summary: String
    @ObservedObject private var updater = AppUpdater.shared


    var body: some View {
        SettingsPage(title: "About", subtitle: "App information and updates.") {
            VStack(spacing: 8) {
                Image(nsImage: icon).resizable().frame(width: 80, height: 80)
                    .accessibilityLabel("\(appName) app icon")
                Text(appName).font(.system(size: 26, weight: .semibold))
                Text("Version \(AppUpdater.currentDisplayVersion)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(SettingsStyle.secondarySurface, in: Capsule())
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)

            SettingsCard(title: "Updates") {
                SettingsRow(title: "Latest version") {
                    HStack(spacing: 16) {
                        Text(updater.latestDisplayVersion ?? (updater.canCheckForUpdates ? "Unavailable" : "Checking…"))
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Button("Check for Updates") { updater.checkForUpdates() }
                            .buttonStyle(SettingsActionStyle()).disabled(!updater.canCheckForUpdates)
                    }
                }
            }
            if let error = updater.startupError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear { updater.refreshVersionInformation() }
    }
}
