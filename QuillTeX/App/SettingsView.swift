import SwiftUI
import AppKit

struct SettingsView: View {
    enum Section: String, CaseIterable {
        case compilation = "Compilation", automation = "Automation", plugins = "Plugins", about = "About"
        var symbol: String {
            switch self {
            case .compilation: "hammer"
            case .automation: "clock"
            case .plugins: "puzzlepiece.extension"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject private var settings: BuildSettings
    @State private var selection: Section
    @FocusState private var focused: Field?
    @State private var showingCustomStrategy = false
    @State private var draftName = ""
    @State private var draftRuns = 2
    @State private var draftBibliography = 0
    @State private var hoveringAddStrategy = false
    private enum Field { case texBin, output }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
    private var icon: NSImage { NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }

    init(settings: BuildSettings = .shared, initialSection: Section = .compilation) {
        _settings = ObservedObject(wrappedValue: settings)
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        SettingsLayout(appName: "QuillTeX", version: version, icon: icon,
                       categories: Section.allCases.map { SettingsCategory(id: $0, title: $0.rawValue, symbol: $0.symbol) },
                       selection: $selection) {
            switch selection {
            case .compilation: compilation
            case .automation: automation
            case .plugins: PluginSettingsPane()
            case .about: about
            }
        }
        .sheet(isPresented: $showingCustomStrategy) { customStrategySheet.tint(.black).preferredColorScheme(.light) }
        .onAppear {
            settings.rescan()
            DispatchQueue.main.async {
                focused = nil
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private var compilation: some View {
        SettingsPage(title: "Compilation", subtitle: "Configure TeX and output.") {
            SettingsCard(title: "TeX installation") {
                HStack(spacing: 8) {
                    Image(systemName: settings.toolchain.isReady ? "checkmark.circle" : "exclamationmark.triangle")
                    Text(settings.toolchain.isReady ? "latexmk is available" : "latexmk was not found")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }.padding(.vertical, 10)
                TextField("TeX bin folder", text: $settings.texBinDirectory)
                    .textFieldStyle(.roundedBorder).focused($focused, equals: .texBin)
                    .accessibilityLabel("TeX bin folder")
                HStack(spacing: 8) {
                    Button("Choose…") { chooseTeXFolder() }.buttonStyle(SettingsActionStyle())
                    Button("Detect Again") { settings.rescan() }.buttonStyle(SettingsActionStyle())
                    Spacer()
                }.padding(.vertical, 10)

            }
            SettingsCard(title: "Output") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output folder").font(.system(size: 13))
                    TextField("Output folder", text: $settings.outputDirectory)
                        .textFieldStyle(.roundedBorder).focused($focused, equals: .output)
                        .accessibilityLabel("Output folder")
                }.padding(.vertical, 8)
            }
            SettingsCard(title: "Compile strategies") {
                ForEach(Array(settings.strategies.enumerated()), id: \.element.id) { index, strategy in
                    if index > 0 { Divider() }
                    SettingsRow(title: strategy.name, subtitle: strategy.detail(engine: settings.engine)) {
                        SettingsIconButton(symbol: "minus.circle", label: "Delete \(strategy.name)") {
                            settings.removeStrategy(id: strategy.id)
                        }.disabled(settings.strategies.count < 2)
                    }
                }
                Divider()
                HStack {
                    Menu {
                        Button("Engine ×3") { add("Engine ×3", runs: 3, bibliography: nil) }
                        Button("Engine ×4") { add("Engine ×4", runs: 4, bibliography: nil) }
                        Divider()
                        Button("Engine + BibTeX") { add("Engine + BibTeX", runs: 2, bibliography: .bibtex) }
                        Button("Engine + Biber") { add("Engine + Biber", runs: 2, bibliography: .biber) }
                        Button("Engine ×2 + BibTeX") { add("Engine ×2 + BibTeX", runs: 3, bibliography: .bibtex) }
                        Divider()
                        Button("Custom…") {
                            draftName = ""; draftRuns = 2; draftBibliography = 0
                            showingCustomStrategy = true
                        }
                    } label: { Label("Add Strategy", systemImage: "plus") }
                    .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(Color.black.opacity(hoveringAddStrategy ? 0.06 : 0.025), in: Capsule())
                    .overlay(Capsule().strokeBorder(SettingsStyle.border, lineWidth: 1))
                    .contentShape(Capsule())
                    .onHover { hoveringAddStrategy = $0 }
                    .accessibilityLabel("Add Strategy")
                    Spacer()
                }.padding(.vertical, 10)
            }
        }
    }

    private var automation: some View {
        SettingsPage(title: "Automation", subtitle: "Set save and compile delays.") {
            SettingsCard(title: "After typing") {
                SettingsRow(title: "Save after") {
                    Stepper(value: $settings.autoSaveDelay, in: 0.2...3, step: 0.1) {
                        Text(String(format: "%.1f s", settings.autoSaveDelay)).monospacedDigit()
                    }.fixedSize().accessibilityLabel("Save after typing")
                }
                Divider()
                SettingsRow(title: "Then compile after") {
                    Stepper(value: $settings.autoCompileDelay, in: 0.2...5, step: 0.1) {
                        Text(String(format: "%.1f s", settings.autoCompileDelay)).monospacedDigit()
                    }.fixedSize().accessibilityLabel("Compile after saving")
                }
            }
        }
    }

    private var about: some View {
        AboutSettingsPane(appName: "QuillTeX", icon: icon,
                          summary: "A focused LaTeX editor.")
    }

    private func add(_ name: String, runs: Int, bibliography: BuildStep?) {
        settings.addStrategy(.custom(name: name, engineRuns: runs, bibliography: bibliography))
    }

    /// A strategy is a name plus how many passes to run, with an optional bibliography
    /// step after the first one — which is the shape people actually ask for.
    private var customStrategySheet: some View {
        let preview = BuildStrategy.custom(name: draftName.isEmpty ? "Custom" : draftName,
                                           engineRuns: draftRuns,
                                           bibliography: draftBibliography == 1 ? .bibtex
                                               : (draftBibliography == 2 ? .biber : nil))
        return VStack(alignment: .leading, spacing: 16) {
            Text("New Compile Strategy").font(.headline)
            TextField("Name", text: $draftName).textFieldStyle(.roundedBorder).frame(width: 300)
            LabeledContent("Engine passes") {
                Stepper(value: $draftRuns, in: 1...6) { Text("\(draftRuns)").monospacedDigit() }
            }
            Picker("Bibliography", selection: $draftBibliography) {
                Text("None").tag(0)
                Text("BibTeX after the first pass").tag(1)
                Text("Biber after the first pass").tag(2)
            }
            Text(preview.detail(engine: settings.engine))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Cancel") { showingCustomStrategy = false }
                Button("Add") { settings.addStrategy(preview); showingCustomStrategy = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 380)
        .onAppear {
            focused = nil
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private func chooseTeXFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.texBinDirectory)
        panel.message = "Choose the folder that contains latexmk"
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { settings.texBinDirectory = url.path }
    }
}
