//
//  recent_projects_view.swift
//  QuillTeX
//
//  The Recent Projects popover: the top bar's clock control opens this in the
//  shared floating panel. Layout, hover wash, per-row delete and the footer
//  Clear History mirror PaperLens's recent history popover so both apps read
//  the same; the data is QuillTeX's document library.
//

import SwiftUI

struct RecentProjectsView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var library: DocumentLibrary
    let onClose: () -> Void

    @State private var selection = 0

    /// The list scrolls inside a bounded height, like the other popovers.
    private var listHeight: CGFloat {
        min(CGFloat(library.recents.count) * 58 + 12, 320)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                QuillPopoverTitle("Recent Projects")
                Spacer(minLength: 12)
                if !library.recents.isEmpty {
                    Button("Clear History") { clearHistory() }.buttonStyle(SettingsActionStyle())
                }
            }
            if library.recents.isEmpty {
                Text("No recent projects").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(library.recents.enumerated()), id: \.element.id) { index, item in
                            let active = selection == index
                            HStack(spacing: 0) {
                                Button { open(item) } label: {
                                    QuillPopupRowLabel(symbol: "doc.text", title: item.title,
                                                       subtitle: Self.shortPath(item.url.deletingLastPathComponent()))
                                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                QuillPopupDeleteButton(title: item.title, visible: active) { forget(item) }
                                    .padding(.trailing, 10)
                            }
                            .quillPopupRow(active: active)
                            .onHover { if $0 { selection = index } }
                        }
                    }
                    .padding(8)
                }.frame(height: listHeight)
            }
        }
        .frame(width: ChromeMetrics.popoverWidth)
        .focusable().focusEffectDisabled()
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(0, library.recents.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.return) {
            if library.recents.indices.contains(selection) { open(library.recents[selection]) }
            return .handled
        }
        .quillPopoverContent()
    }

    /// Closes the panel first, then takes the same path the launcher's recent
    /// rows use: the remembered file is the project's main document.
    private func open(_ item: RecentDocument) {
        onClose()
        store.openProject(item.url, explicitRoot: true)
    }

    /// Only the chosen entry leaves the history; the rest keeps its order.
    private func forget(_ item: RecentDocument) {
        do { try library.remove(item) }
        catch { store.showError("Could Not Update Recents", error.localizedDescription) }
        selection = min(selection, max(0, library.recents.count - 1))
    }

    private func clearHistory() {
        do { try library.clearRecents(); selection = 0 }
        catch { store.showError("Could Not Clear History", error.localizedDescription) }
    }

    /// Library paths read shorter from the home folder outwards.
    private static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
