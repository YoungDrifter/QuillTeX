import SwiftUI
import AppKit

/// The Result sidebar: errors and warnings from the last run, each one a link into
/// the source, plus the raw transcript for the cases the parser cannot name.
struct ResultPanel: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var build: BuildController
    @State private var showsLog = false
    @State private var logHeight: CGFloat = 220
    @State private var dragStartHeight: CGFloat?
    @State private var resizeHovered = false
    @State private var filter = BuildDiagnosticFilter()

    private var filteredDiagnostics: [BuildDiagnostic] { build.diagnostics.filter { $0.severity != .info && filter.includes($0) } }
    private var locatedDiagnostics: [BuildDiagnostic] { filteredDiagnostics.compactMap(store.resolvedDiagnostic) }

    init(store: ProjectStore) {
        self.store = store
        self.build = store.build
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                controls
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                        if build.status.isRunning {
                            Text(build.lastSummary).font(.system(size: 12))
                                .foregroundStyle(.secondary).padding(8)
                        } else if case .succeeded = build.status {
                            EmptyView()
                        } else if build.diagnostics.isEmpty {
                            Text(emptyMessage).font(.system(size: 12))
                                .foregroundStyle(.secondary).padding(8)
                        }
                        if !build.diagnostics.isEmpty && filteredDiagnostics.isEmpty {
                            Text("No matching problems").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                        }
                        severityGroup("Errors", empty: "No errors", items: filteredDiagnostics.filter { $0.severity == .error })
                        severityGroup("Warnings", empty: "No warnings", items: filteredDiagnostics.filter { $0.severity == .warning })
                        }
                        .padding(.horizontal, 8).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: build.selectedDiagnosticID) { _, id in
                        if let id { reader.scrollTo(id, anchor: .center) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !build.log.isEmpty {
                    logSection(availableHeight: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "resultPanel")
        }
    }

    private var controls: some View {
            HStack(spacing: 4) {
                Text("\(filteredDiagnostics.count) problem\(filteredDiagnostics.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize()
                Menu {
                    Button { filter.category = nil } label: {
                        if filter.category == nil { Label("All categories", systemImage: "checkmark") }
                        else { Text("All categories") }
                    }
                    ForEach(BuildDiagnostic.Category.allCases) { category in
                        Button { filter.category = category } label: {
                            if filter.category == category { Label(category.title, systemImage: "checkmark") }
                            else { Text(category.title) }
                        }
                    }
                } label: {
                    Text(compactCategoryTitle)
                }
                .menuStyle(.button).controlSize(.small)
                .help("Filter problems by category").accessibilityLabel("Problem category")
                .accessibilityValue(filter.category?.title ?? "All categories")
                .frame(maxWidth: .infinity)
                Button { navigateProblem(-1) } label: {
                    Image(systemName: "chevron.up").frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(locatedDiagnostics.isEmpty)
                .help("Previous problem").accessibilityLabel("Previous problem")
                Button { navigateProblem(1) } label: {
                    Image(systemName: "chevron.down").frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(locatedDiagnostics.isEmpty)
                .help("Next problem").accessibilityLabel("Next problem")
            }
        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 8)
    }

    private var compactCategoryTitle: String {
        switch filter.category {
        case .compilation: "TeX"
        case .layout: "Layout"
        case .references: "Refs"
        case .bibliography: "Bib"
        case nil: "All"
        }
    }
    @ViewBuilder private func severityGroup(_ title: String, empty: String, items: [BuildDiagnostic]) -> some View {
        if items.isEmpty {
            Label(empty, systemImage: "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 8)
        } else {
            Text("\(title) · \(items.count)")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.top, 9).padding(.bottom, 3)
            ForEach(items) { diagnostic in
                DiagnosticRow(diagnostic: diagnostic, store: store, selected: build.selectedDiagnosticID == diagnostic.id) {
                    build.selectDiagnostic(diagnostic)
                }
                .id(diagnostic.id)
            }
        }
    }

    private func navigateProblem(_ offset: Int) {
        guard let diagnostic = build.neighboringDiagnostic(offset: offset, in: locatedDiagnostics) else { return }
        store.openDiagnostic(diagnostic)
    }

    private var emptyMessage: String {
        switch build.status {
        case .failed: "Compilation failed. See the raw log for details."
        case .unavailable(let reason): reason
        case .idle: build.lastSummary == "Build cancelled" ? "Build cancelled" : "Nothing compiled yet"
        default: "Nothing compiled yet"
        }
    }

    private func logSection(availableHeight: CGFloat) -> some View {
        let maximumHeight = max(0, availableHeight - 110)
        let height = min(logHeight, maximumHeight)
        return VStack(spacing: 0) {
            if showsLog {
                ZStack {
                    Palette.primaryInk.opacity(resizeHovered || dragStartHeight != nil ? 0.07 : 0.025)
                    Capsule()
                        .fill(Palette.primaryInk.opacity(resizeHovered || dragStartHeight != nil ? 0.45 : 0.18))
                        .frame(width: resizeHovered || dragStartHeight != nil ? 44 : 28, height: 3)
                }
                    .frame(height: 10)
                    .animation(.easeInOut(duration: 0.15), value: resizeHovered)
                    .animation(.easeInOut(duration: 0.15), value: dragStartHeight != nil)
                    .contentShape(Rectangle())
                    // Measure in the stationary panel: the handle itself moves
                    // during resizing and cannot provide a stable local origin.
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("resultPanel"))
                        .onChanged { value in
                            let initial = dragStartHeight ?? height
                            dragStartHeight = initial
                            logHeight = min(maximumHeight, max(min(80, maximumHeight), initial - value.translation.height))
                        }
                        .onEnded { _ in dragStartHeight = nil })
                    .onHover { hovering in
                        guard hovering != resizeHovered else { return }
                        resizeHovered = hovering
                        if hovering { NSCursor.resizeUpDown.push() }
                        else { NSCursor.pop() }
                    }
                    .onDisappear {
                        if resizeHovered {
                            NSCursor.pop()
                            resizeHovered = false
                        }
                        dragStartHeight = nil
                    }
                    .accessibilityLabel("Resize raw log")
                    .help("Drag to resize the raw log")
            } else {
                Divider().opacity(0.5)
            }
            Button { showsLog.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsLog ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                    Text("Raw log").font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsLog ? "Collapse raw log" : "Expand raw log")
            if showsLog {
                ScrollView {
                    Text(build.log)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: height)
            }
        }
    }
}

private struct DiagnosticRow: View {
    let diagnostic: BuildDiagnostic
    @ObservedObject var store: ProjectStore
    var selected = false
    var onSelect: () -> Void = {}
    @State private var hover = false

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
                Image(systemName: icon).font(.system(size: 12)).frame(width: 15)
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
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.primaryInk.opacity(selected ? Palette.selectedOpacity : (hover ? Palette.chromeHoverOpacity : 0))))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(store.resolvedDiagnostic(diagnostic) == nil)
        .help(diagnostic.detail.isEmpty ? diagnostic.summary : diagnostic.detail)
    }
}
