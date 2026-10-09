import SwiftUI
import AppKit

/// The compile capsule: gear that starts a build and spins while one runs, the
/// MANUAL/AUTO switch, the engine, quick settings and the result state.
struct BuildControls: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var build: BuildController
    @ObservedObject private var settings = BuildSettings.shared
    @State private var spinning = false

    init(store: ProjectStore) {
        self.store = store
        self.build = store.build
    }

    private var running: Bool { build.status.isRunning }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        HStack(spacing: 7) {
            Button { store.buildNow() } label: {
                // Two gears, each turning about its own centre: the big one clockwise,
                // the small one counter-clockwise, neither one changing position.
                ZStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .regular))
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(spinning ? .linear(duration: 1.8).repeatForever(autoreverses: false) : .default, value: spinning)
                        .offset(x: -2.5, y: -2)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .regular))
                        .rotationEffect(.degrees(spinning ? -360 : 0))
                        .animation(spinning ? .linear(duration: 1.8).repeatForever(autoreverses: false) : .default, value: spinning)
                        .offset(x: 5, y: 4)
                }
                .frame(width: ChromeMetrics.groupedButtonSize, height: ChromeMetrics.groupedButtonSize)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(store.root == nil || !settings.toolchain.isReady)
            .help(store.root == nil ? "Open a project to compile" : "Compile the main file (⌘T)")
            .accessibilityLabel("Compile the main file")

            Button { toggleMode() } label: {
                // Both modes read the same: the word itself says which one is active,
                // so the inactive-looking grey was just noise.
                Text(settings.mode.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
            .help(settings.mode == .manual ? "Manual: compile when asked. Click for automatic." : "Automatic: compile after typing. Click for manual.")

            Divider().frame(height: 14)

            Menu {
                ForEach(BuildEngine.allCases) { engine in
                    Button { store.engine = engine } label: {
                        Label(engine.title, systemImage: store.engine == engine ? "checkmark" : "")
                    }
                }
            } label: {
                // Solid, like the mode label: the capsule carries one weight of text.
                Text(store.engine.title).font(.system(size: 11)).foregroundStyle(Color.primary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Compile engine")

            Divider().frame(height: 14)

            ChromeButton(icon: "slider.horizontal.3", label: "Compile Settings") { store.showBuildSettings = true }
                .popover(isPresented: $store.showBuildSettings) { quickSettings }

            statusIndicator
        }
        .padding(ChromeMetrics.groupInset).quillCapsule()
        .onAppear { spinning = running && !reduceMotion }
        .onChange(of: running) { _, value in spinning = value && !reduceMotion }
    }

    /// A check, a warning, or the running spinner. Clicking it shows the problems.
    private var statusIndicator: some View {
        Button {
            if !build.diagnostics.isEmpty { store.sidebarVisible = true; store.sidebarMode = .result }
        } label: {
            Group {
                switch build.status {
                case .running:
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                case .succeeded:
                    Image(systemName: "checkmark.circle").font(.system(size: 13))
                case .failed, .unavailable:
                    Image(systemName: "exclamationmark.circle").font(.system(size: 13))
                case .idle:
                    Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(build.lastSummary)
        .accessibilityLabel(build.lastSummary)
    }

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compile Settings").font(.headline)
            Picker("Engine", selection: Binding(get: { store.engine }, set: { store.engine = $0 })) {
                ForEach(BuildEngine.allCases) { Text($0.title).tag($0) }
            }
            Picker("Mode", selection: $settings.mode) {
                ForEach(BuildMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Strategy", selection: Binding(get: { store.strategy }, set: { store.strategy = $0 })) {
                ForEach(settings.strategies) { Text($0.name).tag($0) }
            }
            Text(store.strategy.detail(engine: store.engine))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Only the compile choices live here; the path and the rest belong to the
        // Settings window, and a popover closes by clicking away.
        .padding(16).frame(width: 280)
    }

    private func toggleMode() {
        settings.mode = settings.mode == .auto ? .manual : .auto
    }
}
