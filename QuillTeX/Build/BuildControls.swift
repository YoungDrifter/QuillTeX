import SwiftUI
import AppKit

/// The compile capsule: gear that starts a build and spins while one runs, the
/// MANUAL/AUTO switch, the engine, quick settings and the result state.
struct BuildControls: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject private var build: BuildController
    @ObservedObject private var settings = BuildSettings.shared
    @State private var spinning = false
    @State private var showingEnginePicker = false
    @State private var hoveredEngine: BuildEngine?

    init(store: ProjectStore) {
        self.store = store
        self.build = store.build
    }

    private var running: Bool { build.status.isRunning }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        HStack(spacing: 7) {
            Button { store.buildNow() } label: {
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
                .frame(width: ChromeMetrics.controlHeight, height: ChromeMetrics.controlHeight)
                .contentShape(Circle())
            }
            .buttonStyle(ChromeButtonStyle())
            .modifier(ChromeHoverFeedback())
            .chromeControlBoundary()
            .disabled(store.root == nil)
            .help(store.root == nil ? "Open a project to compile" : "Compile the main file (⌘T)")
            .accessibilityLabel("Compile the main file")

            Button { toggleMode() } label: {
                // Both modes read the same: the word itself says which one is active,
                // so the inactive-looking grey was just noise.
                Text(settings.mode.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.primaryInk)
                    .padding(.horizontal, 8).frame(height: 26)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(ChromeHoverFeedback())
            .chromeControlBoundary()
            .help(settings.mode == .manual ? "Manual: compile when asked. Click for automatic." : "Automatic: compile after typing. Click for manual.")

            Divider().frame(height: 14)

            Button { showingEnginePicker.toggle() } label: {
                // Solid, like the mode label: the capsule carries one weight of text.
                HStack(spacing: 4) {
                    Text(store.engine.title).font(.system(size: 11)).foregroundStyle(Palette.primaryInk)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(ChromeHoverFeedback())
            .chromeControlBoundary()
            .popover(isPresented: $showingEnginePicker) { enginePicker }
            .help("Compile engine")

            Divider().frame(height: 14)

            ChromeButton(icon: "slider.horizontal.3", label: "Compile Settings") { store.showBuildSettings = true }
                .popover(isPresented: $store.showBuildSettings) { quickSettings }

            statusIndicator
        }
        .padding(.horizontal, ChromeMetrics.chromeGroupInset).quillCapsule().chromeControlGroup()
        .onAppear { spinning = running && !reduceMotion }
        .onChange(of: running) { _, value in spinning = value && !reduceMotion }
    }

    /// A check, a warning, or the running spinner. Clicking it shows the problems.
    private var statusIndicator: some View {
        Button {
            store.sidebarVisible = true; store.sidebarMode = .result
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
        .modifier(ChromeHoverFeedback())
        .chromeControlBoundary()
        .help(build.lastSummary)
        .accessibilityLabel(build.lastSummary)
    }

    /// The engine choices in the same popover style as the other compile menus.
    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compile Engine").font(.headline)
            VStack(spacing: 2) {
                ForEach(BuildEngine.allCases) { engine in
                    Button {
                        store.engine = engine
                        showingEnginePicker = false
                    } label: {
                        HStack(spacing: 10) {
                            Text(engine.title).font(.system(size: 13))
                            Spacer(minLength: 12)
                            if !settings.toolchain.engines.contains(engine) {
                                Text("Not installed").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                .opacity(store.engine == engine ? 1 : 0)
                        }
                        .foregroundStyle(Palette.primaryInk)
                        .padding(.horizontal, 10).frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!settings.toolchain.engines.contains(engine))
                    .quillPopupRow(active: hoveredEngine == engine)
                    .onHover { hoveredEngine = $0 ? engine : (hoveredEngine == engine ? nil : hoveredEngine) }
                }
            }
        }
        .frame(width: 240).quillPopoverContent()
    }

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compile Settings").font(.headline)
            Picker("Engine", selection: Binding(get: { store.engine }, set: { store.engine = $0 })) {
                ForEach(BuildEngine.allCases) { engine in
                    Text(settings.toolchain.engines.contains(engine) ? engine.title : "\(engine.title) (not installed)")
                        .tag(engine).disabled(!settings.toolchain.engines.contains(engine))
                }
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
        .frame(width: 280).quillPopoverContent()
    }

    private func toggleMode() {
        settings.mode = settings.mode == .auto ? .manual : .auto
    }
}
