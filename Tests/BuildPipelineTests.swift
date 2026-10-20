import AppKit
import Combine
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

        // MARK: Preflight uses the selected engine and strategy

        let executable = "/usr/bin/true"
        check(BuildPreflight.inspect(engine: .xelatex, steps: [.engine, .engine], paths: ["xelatex": executable]).isReady,
              "an engine-only strategy does not require latexmk")
        check(BuildPreflight.inspect(engine: .lualatex, steps: [.latexmk], paths: ["latexmk": executable, "xelatex": executable]).missingTools == ["lualatex"],
              "the selected engine is required even when another engine exists")
        check(BuildPreflight.inspect(engine: .xelatex, steps: [.engine, .biber], paths: ["xelatex": executable]).missingTools == ["biber"],
              "bibliography strategies report their missing tool")
        check(!BuildPreflight.inspect(engine: .xelatex, steps: [], paths: ["xelatex": executable]).isReady,
              "an empty strategy cannot report success")

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
        check(parsed.contains { $0.category == .layout && $0.line == 5 && $0.endLine == 6 },
              "overfull boxes are proofreading issues with a line range")
        check(error?.guidance?.contains("package") == true, "common errors include a concrete next step")

        let proofreadingLog = """
        (./chapters/中文 文件.tex
        Underfull \\hbox (badness 10000) in paragraph at lines 4--8
        LaTeX Warning: Citation `smith2026' on page 1 undefined on input line 9.
        LaTeX Warning: Label `eq:one' multiply defined.
        )
        """
        let proofreading = BuildLogParser.diagnostics(in: proofreadingLog, workingDirectory: directory)
        check(proofreading.count == 3 && proofreading.allSatisfy { $0.category.isProofreading }, "layout, citation and duplicate-label issues share the proofreading group")
        check(proofreading.allSatisfy { $0.file?.lastPathComponent == "中文 文件.tex" }, "parentheses in dimensions do not lose the source file")
        check(proofreading.contains { $0.relatedKey == "smith2026" && $0.line == 9 }, "an unresolved citation keeps its key and line")
        check(proofreading.contains { $0.relatedKey == "eq:one" && $0.guidance?.contains("unique") == true }, "a duplicate label includes its key and repair advice")
        check(BuildLogParser.summary(for: proofreading, succeeded: true).contains("3 proofreading issues"), "successful typesetting reports proofreading separately")
        let wrappedWarning = BuildLogParser.diagnostics(in: "(./main.tex\nLaTeX Warning: Reference `long-label' on page 1 undefined on input line\n  42.\n\nLaTeX Warning: There were undefined references.\n)", workingDirectory: directory)
        check(wrappedWarning.count == 1 && wrappedWarning[0].line == 42 && wrappedWarning[0].relatedKey == "long-label",
              "wrapped warnings keep their line and suppress duplicate summary notices")

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

        // MARK: Bibliography failures and live output without depending on TeX

        let noCitations = "I found no \\citation commands---while reading file main.aux\nI found no \\bibdata command---while reading file main.aux\n(There were 2 error messages)"
        check(!BuildLogParser.stepFailed(.bibtex, exitCode: 2, output: noCitations), "BibTeX with no citations is harmless")
        check(BuildLogParser.stepFailed(.bibtex, exitCode: 2, output: noCitations + "\nI couldn't open database file references.bib"),
              "a missing bibliography is not hidden by a no-citations message")
        check(BuildLogParser.stepFailed(.bibtex, exitCode: 2, output: "I was expecting a comma---line 8 of references.bib"),
              "malformed BibTeX data fails the build")
        let missingCitation = "Warning--I didn't find a database entry for \"missing-key\"\n(There was 1 warning)"
        check(!BuildLogParser.stepFailed(.bibtex, exitCode: 1, output: missingCitation), "BibTeX warning-only status is not a fatal compile error")
        let missingEntry = BuildLogParser.diagnostics(in: missingCitation, workingDirectory: directory)
        check(missingEntry.count == 1 && missingEntry[0].category == .references && missingEntry[0].relatedKey == "missing-key",
              "BibTeX missing entries appear as citation proofreading issues")
        check(!BuildLogParser.stepFailed(.biber, exitCode: 1, output: "WARN - The file main.bcf does not contain any citekeys!"),
              "Biber with no citekeys is harmless")
        check(BuildLogParser.stepFailed(.biber, exitCode: 2, output: "WARN - no citekeys\nERROR - Cannot find references.bib"),
              "a Biber error remains fatal alongside a no-citekeys warning")

        let fixtureMain = directory.appendingPathComponent("fixture.tex")
        try "fixture".write(to: fixtureMain, atomically: true, encoding: .utf8)
        func fixture(_ name: String, body: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        func request(_ paths: [String: String], steps: [BuildStep] = [.engine], sourceRevision: Int? = nil) -> BuildController.Request {
            BuildController.Request(mainFile: fixtureMain, outputDirectory: directory.appendingPathComponent("fixture-output"),
                                    engine: .xelatex, steps: steps, toolPaths: paths, environment: ProcessInfo.processInfo.environment,
                                    sourceRevision: sourceRevision)
        }
        let slow = try fixture("slow-engine", body: "echo 'first output'\nsleep 1.5\necho 'last output'")
        let streaming = BuildController()
        streaming.compile(request(["xelatex": slow]))
        let outputDeadline = Date().addingTimeInterval(1)
        while streaming.status.isRunning && !streaming.log.contains("first output"), Date() < outputDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(streaming.status.isRunning && streaming.log.contains("first output"), "compile output is available before the step finishes (\(streaming.status), \(streaming.log))")
        check(streaming.currentStep == "XeLaTeX", "current step names the selected engine")
        streaming.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check(!streaming.status.isRunning && streaming.lastSummary == "Build cancelled", "cancelled process callbacks cannot publish a later success")
        check(streaming.log.contains("first output"), "cancel preserves the output already received")

        let queuedEngine = try fixture("queued-engine", body: "echo 'queued build'\nsleep 0.35")
        let queued = BuildController()
        var startedRevisions: [Int?] = []
        let queueObserver = queued.$status.sink { status in
            if status.isRunning { startedRevisions.append(queued.activeSourceRevision) }
        }
        queued.compile(request(["xelatex": queuedEngine], sourceRevision: 11))
        check(queued.activeSourceRevision == 11, "an active build retains its saved source revision")
        queued.compile(request(["xelatex": queuedEngine], sourceRevision: 22))
        queued.compile(request(["xelatex": queuedEngine], sourceRevision: 33))
        check(queued.activeSourceRevision == 11, "queued requests cannot replace the active build revision")
        waitForBuild(queued)
        check(startedRevisions == [11, 33], "only the latest follow-up starts, with its own revision already bound when running is published")
        check(queued.activeSourceRevision == 33, "the final success keeps the follow-up source revision")
        queueObserver.cancel()

        let noisyEngine = try fixture("noisy-engine", body: "/usr/bin/awk 'BEGIN { for (i = 0; i < 25000; i++) print \"long output row\" }'")
        let bounded = BuildController()
        bounded.compile(request(["xelatex": noisyEngine]))
        waitForBuild(bounded)
        check(bounded.log.count <= BuildController.maximumLogCharacters, "large compile logs stay within the display capacity")
        let brokenBib = try fixture("broken-bibtex", body: "echo \"I couldn't open database file references.bib\"\nexit 2")
        let bibliography = BuildController()
        bibliography.compile(request(["xelatex": executable, "bibtex": brokenBib], steps: [.engine, .bibtex]))
        waitForBuild(bibliography)
        check({ if case .failed = bibliography.status { return true }; return false }(), "bibliography failure affects the complete build verdict")
        check(bibliography.diagnostics.contains { $0.category == .bibliography && $0.severity == .error }, "bibliography failures produce an actionable diagnostic")

        let navigator = BuildController()
        let firstLocation = BuildDiagnostic(severity: .error, message: "first", file: fixtureMain, line: 1)
        let secondLocation = BuildDiagnostic(severity: .warning, message: "second", file: fixtureMain, line: 3, category: .layout)
        let candidates = [firstLocation, secondLocation]
        check(navigator.neighboringDiagnostic(offset: 1, in: candidates)?.id == firstLocation.id, "problem navigation starts at the first location")
        check(navigator.neighboringDiagnostic(offset: 1, in: candidates)?.id == secondLocation.id, "next problem advances to the next source location")
        check(navigator.neighboringDiagnostic(offset: 1, in: candidates)?.id == firstLocation.id, "problem navigation wraps around")
        check(navigator.neighboringDiagnostic(offset: -1, in: candidates)?.id == secondLocation.id, "previous problem wraps in the other direction")

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
