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

    init(store: ProjectStore) {
        self.store = store
        self.build = store.build
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if case .succeeded = build.status,
                           !build.diagnostics.contains(where: { $0.severity == .error }) {
                            Label("Compiled without errors", systemImage: "checkmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 8)
                        } else if build.status.isRunning {
                            Text("Compiling…").font(.system(size: 12))
                                .foregroundStyle(.secondary).padding(8)
                        } else if build.diagnostics.isEmpty {
                            Text(emptyMessage).font(.system(size: 12))
                                .foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(build.diagnostics) { diagnostic in
                            DiagnosticRow(diagnostic: diagnostic, store: store)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private var emptyMessage: String {
        switch build.status {
        case .failed: "Compilation failed. See the raw log for details."
        default: "Nothing compiled yet"
        }
    }

    private func logSection(availableHeight: CGFloat) -> some View {
        let maximumHeight = max(0, availableHeight - 110)
        let height = min(logHeight, maximumHeight)
        return VStack(spacing: 0) {
            if showsLog {
                ZStack {
                    Color.primary.opacity(resizeHovered || dragStartHeight != nil ? 0.07 : 0.025)
                    Capsule()
                        .fill(Color.primary.opacity(resizeHovered || dragStartHeight != nil ? 0.45 : 0.18))
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
                    Text(build.log.suffix(20_000))
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
            if let file = diagnostic.file { store.openSource(file, line: diagnostic.line ?? 1) }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 15)
                    .foregroundStyle(diagnostic.severity == .error ? Color.primary : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(diagnostic.summary)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !diagnostic.location.isEmpty {
                        Text(diagnostic.location).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hover ? 0.05 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(diagnostic.file == nil)
        .help(diagnostic.detail.isEmpty ? diagnostic.summary : diagnostic.detail)
    }
}
