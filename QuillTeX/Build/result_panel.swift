import SwiftUI

/// Warnings and errors from the last run, with direct links into the source.
struct ResultPanel: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var build: BuildController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var warningsExpanded = true
    @State private var errorsExpanded = true

    private var problems: [BuildDiagnostic] { build.diagnostics.filter { $0.severity != .info } }

    init(store: ProjectStore) {
        self.store = store
        self.build = store.build
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Result").font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("\(problems.count) problem\(problems.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).monospacedDigit()
                }
                Text(summary).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Palette.secondaryInk)
            .padding(.horizontal, 17)

            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        severityGroup("Warnings", icon: "exclamationmark.triangle", severity: .warning, expanded: $warningsExpanded)
                        severityGroup("Errors", icon: "xmark.circle", severity: .error, expanded: $errorsExpanded)
                    }
                    .padding(.horizontal, 9).padding(.bottom, 12)
                }
                .onChange(of: build.selectedDiagnosticID) { _, id in
                    guard let id, let diagnostic = problems.first(where: { $0.id == id }) else { return }
                    // A keyboard navigation selection must reveal a collapsed group.
                    if diagnostic.severity == .warning { warningsExpanded = true }
                    else { errorsExpanded = true }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { reader.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var summary: String {
        switch build.status {
        case .idle: build.lastSummary == "Build cancelled" ? "Build cancelled" : "Nothing compiled yet"
        case .unavailable(let reason): reason
        default: build.lastSummary
        }
    }

    private func severityGroup(_ title: String, icon: String, severity: BuildDiagnostic.Severity,
                               expanded: Binding<Bool>) -> some View {
        let items = problems.filter { $0.severity == severity }
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 7) {
                    QuillSidebarDisclosure(expanded: expanded.wrappedValue)
                    Image(systemName: icon).font(.system(size: 12)).frame(width: ChromeMetrics.sidebarIconWidth)
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 4)
                    Text("\(items.count)").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Palette.secondaryInk)
                }
                .padding(.horizontal, 8).frame(height: ChromeMetrics.sidebarRowHeight).contentShape(Rectangle())
            }
            .buttonStyle(QuillRowButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue("\(items.count), \(expanded.wrappedValue ? "Expanded" : "Collapsed")")
            .help("\(expanded.wrappedValue ? "Collapse" : "Expand") \(title.lowercased())")

            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: 3) {
                    if items.isEmpty {
                        Text("No \(title.lowercased())").font(.system(size: 11)).foregroundStyle(Palette.secondaryInk)
                            .padding(.leading, 32).padding(.vertical, 6)
                    } else {
                        ForEach(items) { diagnostic in
                            DiagnosticRow(diagnostic: diagnostic, store: store, selected: build.selectedDiagnosticID == diagnostic.id) {
                                build.selectDiagnostic(diagnostic)
                            }.id(diagnostic.id)
                        }
                    }
                }
                .transition(reduceMotion ? .identity : .modifier(active: QuillBranchReveal(progress: 0), identity: QuillBranchReveal(progress: 1)))
            }
        }
    }
}

private struct DiagnosticRow: View {
    let diagnostic: BuildDiagnostic
    @ObservedObject var store: ProjectStore
    var selected = false
    var onSelect: () -> Void = {}

    private var icon: String {
        switch diagnostic.severity {
        case .error: "xmark.circle"
        case .warning: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }

    var body: some View {
        Button {
            onSelect()
            store.openDiagnostic(diagnostic)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: ChromeMetrics.sidebarIconWidth)
                    .foregroundStyle(diagnostic.severity == .error ? Palette.primaryInk : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(diagnostic.summary)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !diagnostic.location.isEmpty {
                        Text(diagnostic.location).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let guidance = diagnostic.guidance {
                        Text(guidance).font(.system(size: 10)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuillRowButtonStyle(selected: selected))
        .disabled(store.resolvedDiagnostic(diagnostic) == nil)
        .help(diagnostic.detail.isEmpty ? diagnostic.summary : diagnostic.detail)
    }
}
