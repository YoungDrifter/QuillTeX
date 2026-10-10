import AppKit
import Foundation

/// Covers the type-setting phase: strategy sequences, log parsing and — when TeX is
/// actually installed — a real latexmk run over a scratch project.
@main
struct BuildPipelineTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }; checks += 1
        }

        // MARK: Strategy sequences

        check(BuildStrategy.automatic.steps == [.latexmk], "automatic delegates to latexmk")
        check(BuildStrategy.engineTwice.steps == [.engine, .engine], "engine ×2 runs the engine twice")
        check(BuildStrategy.engineBibTeX.steps == [.engine, .bibtex, .engine, .engine], "engine + BibTeX sequence")
        check(BuildStrategy.engineBiber.steps == [.engine, .biber, .engine, .engine], "engine + Biber sequence")
        check(BuildStrategy.engineBibTeX.detail(engine: .xelatex).contains("BibTeX"), "strategy detail names the steps")

        // Strategies are user data now: any combination can be composed or dropped.
        let fourPasses = BuildStrategy.custom(name: "Engine ×4", engineRuns: 4, bibliography: nil)
        check(fourPasses.steps == [.engine, .engine, .engine, .engine], "four engine passes")
        let twiceWithBib = BuildStrategy.custom(name: "两次加 bib", engineRuns: 3, bibliography: .biber)
        check(twiceWithBib.steps == [.engine, .biber, .engine, .engine], "the bibliography step follows the first pass")
        check(BuildStrategy.custom(name: "  ", engineRuns: 1, bibliography: nil).name == "Custom", "an unnamed strategy gets a name")

        // MARK: Settings persistence (injected suite, so real prefs stay untouched)

        let suiteName = "QuillTeX-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = BuildSettings(defaults: defaults, detectImmediately: false)
        check(settings.mode == .manual, "manual is the default mode")
        check(!settings.compileOnSave, "manual save compilation is opt-in")
        settings.compileOnSave = true
        check(BuildSettings(defaults: defaults, detectImmediately: false).compileOnSave, "compile after saving survives restart")
        settings.compileOnSave = false
        check(!BuildSettings(defaults: defaults, detectImmediately: false).compileOnSave, "compile after saving can be disabled persistently")
        check(settings.strategy == .automatic, "automatic is the default strategy")
        settings.mode = .auto
        let custom = BuildStrategy.custom(name: "Engine ×4", engineRuns: 4, bibliography: nil)
        settings.addStrategy(custom)
        check(settings.strategyID == custom.id, "adding a strategy selects it")
        let reloaded = BuildSettings(defaults: defaults, detectImmediately: false)
        check(reloaded.mode == .auto, "mode round-trips through defaults")
        check(reloaded.strategy(withID: custom.id).steps == [.engine, .engine, .engine, .engine], "a custom strategy round-trips")
        check(reloaded.strategyID == custom.id, "the selection round-trips")
        reloaded.removeStrategy(id: custom.id)
        check(reloaded.strategies.map(\.id).contains(custom.id) == false, "a strategy can be deleted")
        check(reloaded.strategyID != custom.id, "deleting the selected strategy falls back")
        // Engine and strategy are remembered per project.
        let projectA = URL(fileURLWithPath: "/tmp/quilltex-project-a")
        let projectB = URL(fileURLWithPath: "/tmp/quilltex-project-b")
        check(settings.engine(forProject: projectA) == .xelatex, "a new project starts from the global engine")
        check(settings.strategy(forProject: projectA).id == custom.id, "a new project starts from the global strategy")
        settings.setEngine(.lualatex, forProject: projectA)
        settings.setStrategy(.engineBiber, forProject: projectA)
        check(settings.engine(forProject: projectA) == .lualatex, "engine is remembered for the project")
        check(settings.strategy(forProject: projectA) == .engineBiber, "strategy is remembered for the project")
        // Choosing for one project moves the global default with it, so the next
        // project starts where the last one left off.
        check(settings.engine(forProject: projectB) == .lualatex, "a later project inherits the latest global choice")
        check(settings.strategy(forProject: projectB) == .engineBiber, "the global strategy moved too")
        settings.setStrategy(.engineTwice, forProject: projectB)
        check(settings.strategy(forProject: projectA) == .engineBiber, "projects keep their own strategy")
        check(settings.strategy(forProject: projectB) == .engineTwice, "the second project keeps its own")
        // Deleting a strategy clears it from the projects that pointed at it.
        settings.addStrategy(custom)
        settings.setStrategy(custom, forProject: projectA)
        settings.removeStrategy(id: custom.id)
        check(settings.strategy(forProject: projectA) == settings.strategy, "a deleted strategy falls back for projects too")
        defaults.removePersistentDomain(forName: suiteName)

        // MARK: Log parsing

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = """
        This is XeTeX
        (./chapters/中文 文件.tex
        ./chapters/中文 文件.tex:12: Undefined control sequence.
        l.12 \\hbox
                  {x}
        )
        LaTeX Warning: Reference `fig:one' on page 1 undefined on input line 30.
        ! Missing $ inserted.
        <inserted text>
                        $
        l.48 x^2
        )
        Overfull \\hbox (12.0pt too wide) in paragraph at lines 5--6
        """
        let parsed = BuildLogParser.diagnostics(in: log, workingDirectory: directory)
        let error = parsed.first { $0.severity == .error }
        check(error?.line == 12, "file:line error keeps its line")
        check(error?.file?.lastPathComponent == "中文 文件.tex", "error resolves a Chinese relative path")
        check(parsed.contains { $0.severity == .warning && $0.line == 30 }, "warning keeps its input line")
        check(parsed.contains { $0.severity == .error && $0.line == 48 }, "bare ! error takes its file from the open stack")
        check(!parsed.contains { $0.message.contains("Overfull") }, "overfull boxes are not reported as problems")

        // The template-by-absolute-path warning is noise and must not reach the panel.
        let noisy = """
        LaTeX Warning: You have requested package `/Users/someone/Templates/academic-ctexart/academic-ctexart.sty',
        but the package provides `academic-ctexart'.
        """
        check(!BuildLogParser.diagnostics(in: noisy, workingDirectory: directory).contains { $0.severity == .warning },
              "the requested-package warning is filtered out")

        let duplicate = BuildLogParser.diagnostics(in: log + "\n" + log, workingDirectory: directory)
        check(duplicate.count == parsed.count, "a problem reported twice is listed once")
        check(BuildLogParser.summary(for: parsed, succeeded: false).contains("error"), "failure summary counts errors")
        check(BuildLogParser.summary(for: [], succeeded: true) == "Build succeeded", "clean build summary")

        // MARK: A real compile, when TeX is present

        let tools = BuildSettings(defaults: defaults, detectImmediately: false)
        tools.texBinDirectory = "/Library/TeX/texbin"
        tools.rescan()
        guard tools.toolchain.latexmk != nil else {
            print("PASS: \(checks) build-pipeline assertions (TeX not installed — live compile skipped)")
            return
        }

        let main = directory.appendingPathComponent("main.tex")
        let source = """
        \\documentclass{article}
        \\begin{document}
        Hello QuillTeX.
        \\end{document}
        """
        try source.write(to: main, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("out")

        let good = BuildController()
        good.compile(BuildController.Request(mainFile: main,
                                             outputDirectory: output,
                                             engine: .xelatex,
                                             steps: BuildStrategy.automatic.steps,
                                             toolPaths: tools.toolchain.paths,
                                             environment: tools.environment))
        waitForBuild(good)
        check({ if case .succeeded = good.status { return true }; return false }(), "live compile succeeds")
        check(good.pdfURL != nil && FileManager.default.fileExists(atPath: good.pdfURL!.path), "live compile writes a PDF")
        check(good.diagnostics.filter { $0.severity == .error }.isEmpty, "clean document reports no errors")

        // A broken document must come back with the file and line of the mistake.
        try """
        \\documentclass{article}
        \\begin{document}
        \\begin{center}
        \\end{document}
        """.write(to: main, atomically: true, encoding: .utf8)
        let bad = BuildController()
        bad.compile(BuildController.Request(mainFile: main,
                                            outputDirectory: output,
                                            engine: .xelatex,
                                            steps: BuildStrategy.automatic.steps,
                                            toolPaths: tools.toolchain.paths,
                                            environment: tools.environment))
        waitForBuild(bad)
        check({ if case .failed = bad.status { return true }; return false }(), "broken document fails")
        check(bad.diagnostics.contains { $0.severity == .error && $0.file?.lastPathComponent == "main.tex" }, "failure points at the source file")

        // The two-pass strategy runs the engine step by step.
        try source.write(to: main, atomically: true, encoding: .utf8)
        let twice = BuildController()
        twice.compile(BuildController.Request(mainFile: main,
                                              outputDirectory: output,
                                              engine: .xelatex,
                                              steps: BuildStrategy.engineTwice.steps,
                                              toolPaths: tools.toolchain.paths,
                                              environment: tools.environment))
        waitForBuild(twice)
        check(twice.log.contains("===== engine (exit 0) ====="), "engine ×2 ran the engine steps")
        check(twice.log.components(separatedBy: "===== engine").count - 1 == 2, "engine ×2 ran exactly twice")

        print("PASS: \(checks) build-pipeline assertions")
    }

    /// The controller finishes on the main actor, so pump the run loop until it does.
    @MainActor private static func waitForBuild(_ controller: BuildController, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.status.isRunning, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
