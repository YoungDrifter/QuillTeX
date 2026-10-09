import Foundation
import AppKit

/// Runs one build for one project: a sequence of steps, at most one at a time, with a
/// single follow-up request merged in while it works.
@MainActor
final class BuildController: ObservableObject {
    enum Status: Equatable {
        case idle
        case running(Date)
        case succeeded(Date, TimeInterval)
        case failed(Date, TimeInterval)
        case unavailable(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
        var title: String {
            switch self {
            case .idle: "Not built yet"
            case .running: "Compiling…"
            case .succeeded: "Build succeeded"
            case .failed: "Build failed"
            case .unavailable(let reason): reason
            }
        }
    }

    /// Everything a run needs, resolved up front on the main actor.
    struct Request {
        var mainFile: URL
        var outputDirectory: URL
        var engine: BuildEngine
        /// The ordered steps this build runs.
        var steps: [BuildStep]
        var toolPaths: [String: String]
        var environment: [String: String]
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var diagnostics: [BuildDiagnostic] = []
    @Published private(set) var log = ""
    @Published private(set) var pdfURL: URL?
    @Published private(set) var pdfVersion = 0
    @Published private(set) var lastSummary = "Not built yet"
    @Published private(set) var currentStep: String?
    /// Set by a source → PDF sync; the preview scrolls to it.
    @Published private(set) var highlight: PDFHighlight?

    private var process: Process?
    private var logHandle: FileHandle?
    private var logFile: URL?
    private var active: Active?
    private var pendingRequest: Request?
    private var generation = 0

    private struct Active {
        var request: Request
        var steps: [BuildStep]
        var index = 0
        var transcript = ""
        var failed = false
        var started = Date()
        var generation = 0
    }

    // MARK: - Public API

    /// Starts a build. A request that arrives while one is running is merged into a
    /// single follow-up build instead of queueing up.
    func compile(_ request: Request) {
        guard !status.isRunning else { pendingRequest = request; return }
        // latexmk creates -outdir itself, a bare engine does not.
        try? FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        var active = Active(request: request, steps: request.steps, started: Date())
        generation += 1
        active.generation = generation
        self.active = active
        status = .running(Date())
        lastSummary = "Compiling…"
        diagnostics = []
        startNextStep()
    }

    /// Stops the run in flight and makes sure its result is discarded.
    func cancel() {
        generation += 1
        pendingRequest = nil
        active = nil
        if let process, process.isRunning { process.terminate() }
        try? logHandle?.close()
        logHandle = nil
        if let logFile { try? FileManager.default.removeItem(at: logFile) }
        self.logFile = nil
        process = nil
        currentStep = nil
        if status.isRunning { status = .idle; lastSummary = "Build cancelled" }
    }

    /// A new main file must not inherit the previous project's PDF or diagnostics.
    func resetProject() {
        cancel()
        status = .idle; diagnostics = []; log = ""; highlight = nil
        pdfURL = nil; pdfVersion += 1; lastSummary = "Not built yet"
    }

    func highlight(page: Int, point: CGPoint) {
        highlight = PDFHighlight(page: page, point: point, generation: (highlight?.generation ?? 0) + 1)
    }

    /// Points the preview at an existing PDF without building.
    func adoptExistingPDF(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        pdfURL = url
        pdfVersion += 1
        // The pane shows a real document, so the status must not still say "never
        // built" — it is the previous session's output.
        if case .idle = status { lastSummary = "Showing the last build" }
    }

    // MARK: - Steps

    private func startNextStep() {
        guard let active else { return }
        guard active.index < active.steps.count else { finish(active); return }
        let step = active.steps[active.index]
        guard let launch = launchDescription(step: step, request: active.request) else {
            var updated = active
            updated.failed = true
            updated.transcript += "\n[QuillTeX] \(step.title) is not available.\n"
            updated.index += 1
            self.active = updated
            startNextStep()
            return
        }

        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("quilltex-build-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        let handle = (try? FileHandle(forWritingTo: capture)) ?? FileHandle.nullDevice
        logHandle = handle
        logFile = capture

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.directory
        process.environment = launch.environment
        process.standardOutput = handle
        process.standardError = handle
        currentStep = step.title
        lastSummary = "Compiling… \(step.title) \(active.index + 1)/\(active.steps.count)"

        var updated = active
        updated.index += 1
        self.active = updated
        let token = updated.generation

        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                guard let self, token == self.generation, self.active != nil else { return }
                self.collectStepOutput(step: step, exitCode: code)
                self.startNextStep()
            }
        }

        do {
            try process.run()
        } catch {
            try? handle.close()
            self.process = nil
            logHandle = nil
            logFile = nil
            var failed = self.active ?? active
            failed.failed = true
            failed.transcript += "\n[QuillTeX] Could not start \(launch.executable): \(error.localizedDescription)\n"
            self.active = failed
            startNextStep()
        }
    }

    private struct Launch {
        var executable: String
        var arguments: [String]
        var directory: URL
        var environment: [String: String]
    }

    private func launchDescription(step: BuildStep, request: Request) -> Launch? {
        let sourceDirectory = request.mainFile.deletingLastPathComponent()
        let base = request.mainFile.deletingPathExtension().lastPathComponent
        let output = request.outputDirectory
        switch step {
        case .latexmk:
            guard let path = request.toolPaths["latexmk"] else { return nil }
            return Launch(executable: path,
                          arguments: [request.engine.latexmkFlag,
                                      "-interaction=nonstopmode",
                                      "-file-line-error",
                                      "-synctex=1",
                                      "-outdir=\(output.path)",
                                      request.mainFile.lastPathComponent],
                          directory: sourceDirectory,
                          environment: request.environment)
        case .engine:
            guard let path = request.toolPaths[request.engine.executableName] else { return nil }
            return Launch(executable: path,
                          arguments: ["-interaction=nonstopmode",
                                      "-file-line-error",
                                      "-synctex=1",
                                      "-output-directory=\(output.path)",
                                      request.mainFile.lastPathComponent],
                          directory: sourceDirectory,
                          environment: request.environment)
        case .bibtex:
            guard let path = request.toolPaths["bibtex"] else { return nil }
            var environment = request.environment
            // The .aux lands in the output folder while the .bib stays in the project.
            environment["BIBINPUTS"] = sourceDirectory.path + ":" + (environment["BIBINPUTS"] ?? "")
            environment["BSTINPUTS"] = sourceDirectory.path + ":" + (environment["BSTINPUTS"] ?? "")
            return Launch(executable: path, arguments: [base], directory: output, environment: environment)
        case .biber:
            guard let path = request.toolPaths["biber"] else { return nil }
            var environment = request.environment
            environment["BIBINPUTS"] = sourceDirectory.path + ":" + (environment["BIBINPUTS"] ?? "")
            return Launch(executable: path, arguments: [base], directory: output, environment: environment)
        }
    }

    /// Appends one step's output and notes whether it changes the verdict.
    private func collectStepOutput(step: BuildStep, exitCode: Int32) {
        try? logHandle?.close()
        logHandle = nil
        process = nil
        let text = logFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if let logFile { try? FileManager.default.removeItem(at: logFile) }
        self.logFile = nil
        var updated = active
        updated?.transcript += "\n===== \(step.title) (exit \(exitCode)) =====\n" + text
        // BibTeX and Biber return non-zero for "no citations found", which is not a
        // build failure; only the typesetting steps decide the verdict.
        if exitCode != 0, step == .latexmk || step == .engine { updated?.failed = true }
        active = updated
    }

    private func finish(_ active: Active) {
        let duration = Date().timeIntervalSince(active.started)
        let request = active.request
        let directory = request.mainFile.deletingLastPathComponent()

        // The TeX transcript carries the precise `file:line:` records.
        let transcriptFile = request.outputDirectory
            .appendingPathComponent(request.mainFile.deletingPathExtension().lastPathComponent + ".log")
        let transcript = (try? String(contentsOf: transcriptFile, encoding: .utf8)) ?? ""
        let combined = active.transcript + "\n" + transcript
        log = active.transcript.isEmpty ? transcript : active.transcript

        let found = BuildLogParser.diagnostics(in: combined, workingDirectory: directory)
        diagnostics = found
        let succeeded = !active.failed
        status = succeeded ? .succeeded(Date(), duration) : .failed(Date(), duration)
        lastSummary = BuildLogParser.summary(for: found, succeeded: succeeded)
        if succeeded {
            let pdf = request.outputDirectory
                .appendingPathComponent(request.mainFile.deletingPathExtension().lastPathComponent + ".pdf")
            if FileManager.default.fileExists(atPath: pdf.path) {
                pdfURL = pdf
                pdfVersion += 1
            }
        }
        currentStep = nil
        self.active = nil

        if let pendingRequest {
            self.pendingRequest = nil
            compile(pendingRequest)
        }
    }
}
