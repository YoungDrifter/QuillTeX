import Foundation

/// One step of a build. A strategy is nothing but an ordered list of these.
enum BuildStep: String, Codable, CaseIterable, Identifiable {
    case latexmk, engine, bibtex, biber

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latexmk: "latexmk"
        case .engine: "engine"
        case .bibtex: "BibTeX"
        case .biber: "Biber"
        }
    }
}

/// A named sequence of steps.
///
/// Users add and remove their own, so a strategy is data rather than a fixed enum:
/// `presets` is only the set offered on first run, and everything stays editable.
struct BuildStrategy: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var steps: [BuildStep]

    /// "XeLaTeX · BibTeX · XeLaTeX · XeLaTeX"
    func detail(engine: BuildEngine) -> String {
        steps.map { $0 == .engine ? engine.title : $0.title }.joined(separator: " · ")
    }

    /// The shape people ask for most: N engine passes, optionally with a bibliography
    /// step right after the first one.
    static func custom(name: String, engineRuns: Int, bibliography: BuildStep?) -> BuildStrategy {
        var steps: [BuildStep] = [.engine]
        if let bibliography { steps.append(bibliography) }
        steps.append(contentsOf: Array(repeating: BuildStep.engine, count: max(0, engineRuns - 1)))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return BuildStrategy(id: UUID().uuidString, name: trimmed.isEmpty ? "Custom" : trimmed, steps: steps)
    }

    static let automatic = BuildStrategy(id: "automatic", name: "Automatic (latexmk)", steps: [.latexmk])
    static let engineTwice = BuildStrategy(id: "engineTwice", name: "Engine ×2", steps: [.engine, .engine])
    static let engineBibTeX = BuildStrategy(id: "engineBibTeX", name: "Engine + BibTeX",
                                            steps: [.engine, .bibtex, .engine, .engine])
    static let engineBiber = BuildStrategy(id: "engineBiber", name: "Engine + Biber",
                                           steps: [.engine, .biber, .engine, .engine])

    /// Offered on first run; the user may keep, delete or replace any of them.
    static let presets: [BuildStrategy] = [.automatic, .engineTwice, .engineBibTeX, .engineBiber]
}
