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
    @State private var showingStrategies = false
    @Namespace private var modeSelection
    @Namespace private var engineSelection

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
            .buttonStyle(ChromeButtonStyle())
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
            .buttonStyle(ChromeButtonStyle())
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
        .buttonStyle(ChromeButtonStyle())
        .modifier(ChromeHoverFeedback())
        .chromeControlBoundary()
        .help(build.lastSummary)
        .accessibilityLabel(build.lastSummary)
    }

    /// The engine choices in the same popover style as the other compile menus.
    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuillPopoverTitle("Compile Engine")
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
                    .buttonStyle(QuillRowButtonStyle(selected: engine == store.engine))
                    .disabled(!settings.toolchain.engines.contains(engine))
                }
            }
        }
        .frame(width: 200).quillPopoverContent(padding: 12)
    }

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuillPopoverTitle("Compile Settings").padding(.bottom, 4)
            QuillPopoverSettingRow(title: "Engine") {
                HStack(spacing: 2) {
                    ForEach(BuildEngine.allCases) { engine in
                        Button { store.engine = engine } label: {
                            Text(engine.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                .frame(maxWidth: .infinity).frame(height: 30)
                        }
                        .buttonStyle(ChromeButtonStyle(selected: store.engine == engine, selectionNamespace: engineSelection))
                        .modifier(ChromeHoverFeedback(selected: store.engine == engine))
                        .disabled(!settings.toolchain.engines.contains(engine))
                        .help(settings.toolchain.engines.contains(engine) ? engine.title : "Not installed")
                        .accessibilityAddTraits(store.engine == engine ? .isSelected : [])
                    }
                }
                .padding(2).background(Palette.subtleSurface, in: Capsule())
                .animation(reduceMotion ? nil : ChromeMotion.press, value: store.engine)
            }
            QuillPopoverSettingRow(title: "Mode") {
                HStack(spacing: 2) {
                    ForEach(BuildMode.allCases) { mode in
                        Button { settings.mode = mode } label: {
                            Text(mode.title).font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity).frame(height: 30)
                        }
                        .buttonStyle(ChromeButtonStyle(selected: settings.mode == mode, selectionNamespace: modeSelection))
                        .modifier(ChromeHoverFeedback(selected: settings.mode == mode))
                        .accessibilityAddTraits(settings.mode == mode ? .isSelected : [])
                    }
                }
                .padding(2).background(Palette.subtleSurface, in: Capsule())
                .animation(reduceMotion ? nil : ChromeMotion.press, value: settings.mode)
            }
            QuillPopoverSettingRow(title: "Strategy") {
                VStack(spacing: 6) {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { showingStrategies.toggle() }
                    } label: {
                        Text(store.strategy.name).font(.system(size: 11, weight: .medium))
                            .lineLimit(1).padding(.horizontal, 26)
                            .frame(maxWidth: .infinity).frame(height: ChromeMetrics.popoverControlHeight)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                                    .rotationEffect(.degrees(showingStrategies ? 90 : 0)).padding(.trailing, 12)
                            }
                    }
                    .buttonStyle(ChromeButtonStyle()).modifier(ChromeHoverFeedback())
                    .background(Palette.subtleSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.7).allowsHitTesting(false))
                    .accessibilityLabel("Strategy")
                    .accessibilityValue(store.strategy.name + (showingStrategies ? ", Expanded" : ", Collapsed"))
                    if showingStrategies {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(settings.strategies) { strategy in
                                    Button {
                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                            store.strategy = strategy; showingStrategies = false
                                        }
                                    } label: {
                                        Text(strategy.name).font(.system(size: 11)).lineLimit(1)
                                            .padding(.horizontal, 24).frame(maxWidth: .infinity).frame(height: 30)
                                            .overlay(alignment: .trailing) {
                                                if store.strategy == strategy {
                                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).padding(.trailing, 10)
                                                }
                                            }
                                            .contentShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(QuillRowButtonStyle(selected: store.strategy == strategy))
                                    .accessibilityAddTraits(store.strategy == strategy ? .isSelected : [])
                                }
                            }.padding(4)
                        }
                        .frame(height: min(CGFloat(settings.strategies.count) * 32 + 6, 180))
                        .background(Palette.subtleSurface, in: RoundedRectangle(cornerRadius: 12))
                        .transition(reduceMotion ? .identity : .modifier(
                            active: QuillBranchReveal(progress: 0), identity: QuillBranchReveal(progress: 1)))
                    }
                }
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: ChromeMetrics.popoverLabelWidth, height: 0)
                Text(store.strategy.detail(engine: store.engine))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: ChromeMetrics.popoverWidth).quillPopoverContent()
        .onDisappear { showingStrategies = false }
    }

    private func toggleMode() {
        settings.mode = settings.mode == .auto ? .manual : .auto
    }
}
