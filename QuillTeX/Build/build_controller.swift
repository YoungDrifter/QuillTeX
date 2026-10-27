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
        var sourceRevision: Int? = nil
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var diagnostics: [BuildDiagnostic] = []
    @Published private(set) var log = ""
    @Published private(set) var pdfURL: URL?
    @Published private(set) var pdfVersion = 0
    @Published private(set) var lastSummary = "Not built yet"
    @Published private(set) var currentStep: String?
    @Published private(set) var selectedDiagnosticID: UUID?
    private(set) var activeSourceRevision: Int?
    /// Set by a source → PDF sync; the preview scrolls to it.
    @Published private(set) var highlight: PDFHighlight?

    private var process: Process?
    private var logHandle: FileHandle?
    private var logFile: URL?
    private var logReader: FileHandle?
    private var logPollingTask: Task<Void, Never>?
    private var stepOutput = Data()
    private var active: Active?
    private var pendingRequest: Request?
    private var generation = 0
    /// Retain a useful tail while bounding both the live output and SwiftUI text.
    static let maximumLogCharacters = 200_000
    private static let maximumStepBytes = 800_000

    private struct Active {
        var request: Request
        var steps: [BuildStep]
        var index = 0
        var transcript = ""
        var failed = false
        var started = Date()
        var generation = 0
        var stepDiagnostics: [BuildDiagnostic] = []
    }

    // MARK: - Public API

    /// Starts a build. A request that arrives while one is running is merged into a
    /// single follow-up build instead of queueing up.
    func compile(_ request: Request) {
        guard !status.isRunning else { pendingRequest = request; return }
        let preflight = BuildPreflight.inspect(engine: request.engine, steps: request.steps, paths: request.toolPaths)
        guard preflight.isReady else {
            status = .unavailable(preflight.message)
            lastSummary = preflight.message
            log = preflight.message
            diagnostics = [BuildDiagnostic(severity: .error, message: preflight.message, file: nil, line: nil)]
            selectedDiagnosticID = nil
            return
        }
        // latexmk creates -outdir itself, a bare engine does not.
        do {
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        } catch {
            let message = "Could not create the output folder: \(error.localizedDescription)"
            status = .unavailable(message); lastSummary = message; log = message
            diagnostics = [BuildDiagnostic(severity: .error, message: message, file: nil, line: nil)]
            selectedDiagnosticID = nil
            return
        }
        var active = Active(request: request, steps: request.steps, started: Date())
        generation += 1
        active.generation = generation
        self.active = active
        activeSourceRevision = request.sourceRevision
        status = .running(Date())
        lastSummary = "Compiling…"
        diagnostics = []
        selectedDiagnosticID = nil
        log = ""
        startNextStep()
    }

    /// Stops the run in flight and makes sure its result is discarded.
    func cancel() {
        readStepOutput()
        generation += 1
        pendingRequest = nil
        active = nil
        if let process, process.isRunning { process.terminate() }
        closeStepCapture()
        process = nil
        currentStep = nil
        if status.isRunning {
            status = .idle; lastSummary = "Build cancelled"
            log = bounded(log + "\n[QuillTeX] Build cancelled.\n")
        }
    }

    /// A new main file must not inherit the previous project's PDF or diagnostics.
    func resetProject() {
        cancel()
        status = .idle; diagnostics = []; log = ""; highlight = nil; selectedDiagnosticID = nil
        pdfURL = nil; pdfVersion += 1; lastSummary = "Not built yet"
    }

    func highlight(page: Int, point: CGPoint, width: CGFloat = 0, height: CGFloat = 0) {
        highlight = PDFHighlight(page: page, point: point, width: width, height: height, generation: (highlight?.generation ?? 0) + 1)
    }

    func selectDiagnostic(_ diagnostic: BuildDiagnostic) { selectedDiagnosticID = diagnostic.id }

    /// Wrap through the visible source locations; result filters supply candidates.
    func neighboringDiagnostic(offset: Int, in candidates: [BuildDiagnostic]? = nil) -> BuildDiagnostic? {
        let locations = (candidates ?? diagnostics).filter { $0.file != nil && $0.line != nil }
        guard !locations.isEmpty else { return nil }
        let index: Int
        if let selectedDiagnosticID, let current = locations.firstIndex(where: { $0.id == selectedDiagnosticID }) {
            index = (current + offset % locations.count + locations.count) % locations.count
        } else {
            index = offset < 0 ? locations.count - 1 : 0
        }
        let diagnostic = locations[index]
        selectDiagnostic(diagnostic)
        return diagnostic
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
            failCurrentStep(step, message: "\(step.title) is not available.")
            return
        }

        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("quilltex-build-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: capture),
              let reader = try? FileHandle(forReadingFrom: capture) else {
            try? FileManager.default.removeItem(at: capture)
            failCurrentStep(step, message: "Could not capture the compile log.")
            return
        }
        logHandle = handle
        logFile = capture
        logReader = reader
        stepOutput = Data()

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.directory
        process.environment = launch.environment
        process.standardOutput = handle
        process.standardError = handle
        currentStep = step == .engine ? active.request.engine.title : step.title
        lastSummary = "Compiling… \(currentStep ?? step.title) \(active.index + 1)/\(active.steps.count)"

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
            logPollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self, token == self.generation, self.active != nil else { return }
                    self.readStepOutput()
                }
            }
        } catch {
            self.process = nil
            closeStepCapture()
            failCurrentStep(step, message: "Could not start \(launch.executable): \(error.localizedDescription)", alreadyAdvanced: true)
        }
    }

    private func failCurrentStep(_ step: BuildStep, message: String, alreadyAdvanced: Bool = false) {
        guard var active else { return }
        active.failed = true
        active.transcript = bounded(active.transcript + "\n[QuillTeX] \(message)\n")
        active.stepDiagnostics.append(BuildDiagnostic(severity: .error, message: message, file: nil, line: nil,
                                                       category: step == .bibtex || step == .biber ? .bibliography : .compilation))
        if !alreadyAdvanced { active.index += 1 }
        self.active = active
        log = active.transcript
        startNextStep()
    }

    private func bounded(_ text: String) -> String { String(text.suffix(Self.maximumLogCharacters)) }

    private func readStepOutput(drain: Bool = false) {
        guard let logReader, let active else { return }
        var chunks = 0
        while drain || chunks < 8 {
            guard let data = try? logReader.read(upToCount: 32_768), !data.isEmpty else { break }
            stepOutput.append(data)
            if stepOutput.count > Self.maximumStepBytes {
                stepOutput.removeFirst(stepOutput.count - Self.maximumStepBytes)
                // Do not start the decoded tail halfway through a UTF-8 scalar.
                while let byte = stepOutput.first, byte & 0xC0 == 0x80 { stepOutput.removeFirst() }
            }
            chunks += 1
        }
        let output = String(decoding: stepOutput, as: UTF8.self)
        log = bounded(active.transcript + "\n===== \(currentStep ?? "Compile") · running =====\n" + output)
    }

    private func closeStepCapture() {
        logPollingTask?.cancel(); logPollingTask = nil
        try? logHandle?.close(); logHandle = nil
        try? logReader?.close(); logReader = nil
        if let logFile { try? FileManager.default.removeItem(at: logFile) }
        logFile = nil
        stepOutput = Data()
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
        readStepOutput(drain: true)
        process = nil
        let text = String(decoding: stepOutput, as: UTF8.self)
        closeStepCapture()
        var updated = active
        let previousTranscript = updated?.transcript ?? ""
        updated?.transcript = bounded(previousTranscript + "\n===== \(step.title) (exit \(exitCode)) =====\n" + text)
        if BuildLogParser.stepFailed(step, exitCode: exitCode, output: text) {
            updated?.failed = true
            if step == .bibtex || step == .biber {
                let message = text.split(separator: "\n").first { line in
                    line.localizedCaseInsensitiveContains("ERROR") || line.contains("I couldn't") || line.contains("I was expecting")
                }.map(String.init) ?? "\(step.title) failed (exit \(exitCode))."
                updated?.stepDiagnostics.append(BuildDiagnostic(severity: .error, message: message, file: nil, line: nil,
                                                                 detail: text, category: .bibliography))
            }
        }
        active = updated
        log = updated?.transcript ?? log
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
        log = bounded(active.transcript.isEmpty ? transcript : active.transcript)

        let found = BuildLogParser.diagnostics(in: combined, workingDirectory: directory).map { diagnostic in
            var diagnostic = diagnostic
            if diagnostic.file == nil && diagnostic.line != nil { diagnostic.file = request.mainFile }
            return diagnostic
        } + active.stepDiagnostics
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
