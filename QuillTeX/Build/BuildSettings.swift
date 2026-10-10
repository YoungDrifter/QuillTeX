import Foundation
import Combine

/// Which LaTeX engine `latexmk` drives.
enum BuildEngine: String, CaseIterable, Identifiable, Codable {
    case xelatex, pdflatex, lualatex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .xelatex: "XeLaTeX"
        case .pdflatex: "pdfLaTeX"
        case .lualatex: "LuaLaTeX"
        }
    }
    var executableName: String { rawValue }
    /// `latexmk -xelatex` / `-pdflatex` / `-lualatex`
    var latexmkFlag: String { "-" + rawValue }
}

/// Manual compiles on demand; automatic compiles after the buffer settles.
enum BuildMode: String, CaseIterable, Identifiable, Codable {
    case manual, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "MANUAL"
        case .auto: "AUTO"
        }
    }
}

/// What the app could find on this machine. Detection is deliberately explicit:
/// phase two must keep working (and say so) when TeX is not installed.
struct TeXToolchain: Equatable {
    var directory: String = ""
    var latexmk: String?
    var synctex: String?
    var engines: [BuildEngine] = []
    /// Every tool found in the folder, by executable name, handed to the build so it
    /// can pick the ones a strategy needs.
    var paths: [String: String] = [:]
    /// A missing toolchain is a normal state, not an error: editing stays available.
    var isReady: Bool { latexmk != nil && !engines.isEmpty }
    var summary: String {
        guard latexmk != nil else { return "latexmk not found" }
        guard !engines.isEmpty else { return "No LaTeX engine found" }
        return engines.map(\.title).joined(separator: " · ")
    }
}

/// Compile preferences. Global rather than per project: they describe the machine.
@MainActor
final class BuildSettings: ObservableObject {
    static let shared = BuildSettings()

    @Published var requireMainFile: Bool {
        didSet { defaults.set(requireMainFile, forKey: Key.requireMainFile) }
    }
    @Published var texBinDirectory: String {
        didSet { defaults.set(texBinDirectory, forKey: Key.texBin); rescan() }
    }
    @Published var engine: BuildEngine {
        didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
    }
    @Published var mode: BuildMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    /// The compile strategies on offer: seeded from the presets, then owned by the user.
    @Published private(set) var strategies: [BuildStrategy] {
        didSet { persist(strategies, forKey: Key.strategies) }
    }
    /// Which strategy a build uses when the project has not chosen one of its own.
    @Published var strategyID: String {
        didSet { defaults.set(strategyID, forKey: Key.strategy) }
    }
    /// The strategy the global setting points at.
    var strategy: BuildStrategy { strategy(withID: strategyID) }

    func strategy(withID id: String) -> BuildStrategy {
        strategies.first { $0.id == id } ?? strategies.first ?? BuildStrategy.automatic
    }

    /// Adds a strategy and selects it, so the next build uses it straight away.
    func addStrategy(_ strategy: BuildStrategy) {
        strategies.append(strategy)
        strategyID = strategy.id
    }

    /// Removes one. The last remaining strategy cannot be deleted, and removing the
    /// selected one falls back to the first, so a build always has steps to run.
    func removeStrategy(id: String) {
        guard strategies.count > 1 else { return }
        strategies.removeAll { $0.id == id }
        if strategyID == id { strategyID = strategies.first?.id ?? BuildStrategy.automatic.id }
        forProjectCleanup(removed: id)
    }
    /// Where the compiler writes, relative to the main file unless absolute.
    /// The default keeps everything beside the document.
    @Published var outputDirectory: String {
        didSet { defaults.set(outputDirectory, forKey: Key.output) }
    }
    /// Seconds of quiet typing before AUTO saves, then before it compiles.
    @Published var autoSaveDelay: Double {
        didSet { defaults.set(autoSaveDelay, forKey: Key.autoSave) }
    }
    @Published var autoCompileDelay: Double {
        didSet { defaults.set(autoCompileDelay, forKey: Key.autoCompile) }
    }
    @Published var compileOnSave: Bool {
        didSet { defaults.set(compileOnSave, forKey: Key.compileOnSave) }
    }
    @Published private(set) var toolchain = TeXToolchain()

    private let defaults: UserDefaults

    // MARK: - Per-project choices

    /// Compile choices belong to a project: one document may want two XeLaTeX passes
    /// while the next is happy with latexmk. Changing a value also updates the global
    /// default, so a brand-new project starts from the most recent choice.
    func engine(forProject directory: URL?) -> BuildEngine {
        guard let raw = stored(forProject: directory)?["engine"], let value = BuildEngine(rawValue: raw) else { return engine }
        return value
    }

    func strategy(forProject directory: URL?) -> BuildStrategy {
        guard let id = stored(forProject: directory)?["strategy"] else { return strategy }
        return strategy(withID: id)
    }

    func setEngine(_ value: BuildEngine, forProject directory: URL?) {
        engine = value
        store(["engine": value.rawValue], forProject: directory)
    }

    func setStrategy(_ value: BuildStrategy, forProject directory: URL?) {
        strategyID = value.id
        store(["strategy": value.id], forProject: directory)
    }

    /// A project that pointed at a deleted strategy should not keep a dead id.
    private func forProjectCleanup(removed id: String) {
        var table = projectTable()
        var changed = false
        for (key, var values) in table where values["strategy"] == id {
            values.removeValue(forKey: "strategy")
            table[key] = values
            changed = true
        }
        if changed { defaults.set(table, forKey: Key.projects) }
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// Drops every remembered per-project choice; the global values stay.
    func clearProjectChoices() {
        defaults.removeObject(forKey: Key.projects)
    }

    private func projectTable() -> [String: [String: String]] {
        defaults.dictionary(forKey: Key.projects) as? [String: [String: String]] ?? [:]
    }

    private func stored(forProject directory: URL?) -> [String: String]? {
        guard let directory else { return nil }
        return projectTable()[directory.standardizedFileURL.path]
    }

    private func store(_ values: [String: String], forProject directory: URL?) {
        guard let directory else { return }
        var table = projectTable()
        let key = directory.standardizedFileURL.path
        table[key, default: [:]].merge(values) { _, new in new }
        defaults.set(table, forKey: Key.projects)
    }

    private enum Key {
        static let requireMainFile = "opening.requireMainFile"
        static let texBin = "build.texBinDirectory"
        static let engine = "build.engine"
        static let mode = "build.mode"
        static let strategy = "build.strategy"
        static let strategies = "build.strategies"
        static let output = "build.outputDirectory"
        static let projects = "build.projects"
        static let autoSave = "build.autoSaveDelay"
        static let autoCompile = "build.autoCompileDelay"
        static let compileOnSave = "build.compileOnSave"
    }

    init(defaults: UserDefaults = .standard, detectImmediately: Bool = true) {
        self.defaults = defaults
        requireMainFile = defaults.object(forKey: Key.requireMainFile) as? Bool ?? true
        let stored = defaults.string(forKey: Key.texBin)
        texBinDirectory = stored ?? Self.defaultTeXBinDirectory()
        engine = defaults.string(forKey: Key.engine).flatMap(BuildEngine.init(rawValue:)) ?? .xelatex
        mode = defaults.string(forKey: Key.mode).flatMap(BuildMode.init(rawValue:)) ?? .manual
        if let data = defaults.data(forKey: Key.strategies),
           let stored = try? JSONDecoder().decode([BuildStrategy].self, from: data), !stored.isEmpty {
            strategies = stored
        } else {
            strategies = BuildStrategy.presets
        }
        strategyID = defaults.string(forKey: Key.strategy) ?? BuildStrategy.automatic.id
        outputDirectory = defaults.string(forKey: Key.output) ?? "."
        autoSaveDelay = defaults.object(forKey: Key.autoSave) as? Double ?? 0.5
        autoCompileDelay = defaults.object(forKey: Key.autoCompile) as? Double ?? 0.5
        compileOnSave = defaults.bool(forKey: Key.compileOnSave)
        if detectImmediately { rescan() }
    }

    /// `/Library/TeX/texbin` is where MacTeX puts its binaries; fall back to the
    /// usual package-manager prefixes so a TeX Live from Homebrew still works.
    static func defaultTeXBinDirectory() -> String {
        let candidates = ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path + "/latexmk") { return path }
        return "/Library/TeX/texbin"
    }

    func rescan() {
        let directory = (texBinDirectory as NSString).expandingTildeInPath
        var found = TeXToolchain(directory: directory)
        func executable(_ name: String) -> String? {
            let path = (directory as NSString).appendingPathComponent(name)
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        found.latexmk = executable("latexmk")
        found.synctex = executable("synctex")
        found.engines = BuildEngine.allCases.filter { executable($0.executableName) != nil }
        for name in ["latexmk", "synctex", "bibtex", "biber", "makeindex", "bibtex8"]
            + BuildEngine.allCases.map(\.executableName) {
            if let path = executable(name) { found.paths[name] = path }
        }
        toolchain = found
    }

    /// PATH for the compiler: the configured TeX directory first, then the usual
    /// system locations, otherwise latexmk cannot find its engine.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = (texBinDirectory as NSString).expandingTildeInPath
        let base = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = base.hasPrefix(directory) ? base : directory + ":" + base
        return environment
    }

    var latexmkPath: String? { toolchain.latexmk }
    var synctexPath: String? { toolchain.synctex }
}
