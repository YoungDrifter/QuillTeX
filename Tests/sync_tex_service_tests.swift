import Foundation
import CoreGraphics

@main
struct SyncTeXServiceTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            checks += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTeX tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = directory.appendingPathComponent("output.pdf")
        let source = directory.appendingPathComponent("source file.tex")
        let syncData = directory.appendingPathComponent("output.synctex.gz")
        let executable = directory.appendingPathComponent("mock synctex")
        try Data().write(to: pdf)
        try Data().write(to: syncData)
        func script(_ body: String) throws {
            try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let forwardOutput = """
        SyncTeX result begin
        Output:output.pdf
        Page:2
        x:80.25
        y:120.5
        h:75.25
        v:125.5
        W:250
        H:12
        Output:output.pdf
        Page:9
        x:300
        y:400
        SyncTeX result end
        """
        let parsed = try SyncTeXService.parseForward(forwardOutput)
        check(parsed.page == 2, "forward search uses the closest record")
        check(parsed.point == CGPoint(x: 75.25, y: 125.5), "forward search uses the enclosing box origin")
        check(parsed.width == 250 && parsed.height == 12, "forward search preserves target box dimensions")
        let fallback = try SyncTeXService.parseForward("SyncTeX result begin\nPage:1\nx:25\ny:30\nSyncTeX result end")
        check(fallback.point == CGPoint(x: 25, y: 30), "point-only records remain supported")
        do {
            _ = try SyncTeXService.parseForward("SyncTeX result begin\nPage:1\nx:nan\ny:30\nSyncTeX result end")
            fatalError("FAILED: invalid coordinates must not reach PDFKit")
        } catch SyncTeXService.Failure.invalidResult { checks += 1 }
        let inverse = try SyncTeXService.parseInverse("SyncTeX result begin\nInput:./chapter:one.tex\nLine:42\nColumn:-1\nSyncTeX result end", pdf: pdf)
        check(inverse.file == directory.appendingPathComponent("chapter:one.tex"), "inverse paths retain colons and resolve relative to the PDF")
        check(inverse.line == 42 && inverse.column == nil, "unknown inverse columns remain absent")
        let sourceDirectory = directory.appendingPathComponent("source root", isDirectory: true)
        let separatePDF = directory.appendingPathComponent("output directory/output.pdf")
        let relativeInverse = try SyncTeXService.parseInverse("SyncTeX result begin\nInput:./chapters/one.tex\nLine:8\nSyncTeX result end",
                                                            pdf: separatePDF, sourceDirectory: sourceDirectory)
        check(relativeInverse.file == sourceDirectory.appendingPathComponent("chapters/one.tex"),
              "inverse search resolves relative input files from the compiler source directory")
        let absoluteInverse = try SyncTeXService.parseInverse("SyncTeX result begin\nInput:\(source.path)\nLine:9\nSyncTeX result end",
                                                            pdf: separatePDF, sourceDirectory: sourceDirectory)
        check(absoluteInverse.file == source, "inverse search preserves absolute input paths with a separate output directory")
        try script("cat <<'RESULT'\n\(forwardOutput)\nRESULT")
        let found = try await SyncTeXService.forward(line: 9, file: source, pdf: pdf, executable: executable.path)
        check(found.page == 2 && found.width == 250, "asynchronous lookup supports paths with spaces")
        try script("i=0; while [ $i -lt 6000 ]; do printf 'diagnostic diagnostic diagnostic\\n' >&2; i=$((i + 1)); done\ncat <<'RESULT'\n\(forwardOutput)\nRESULT")
        let noisy = try await SyncTeXService.forward(line: 9, file: source, pdf: pdf, executable: executable.path)
        check(noisy.page == 2, "verbose stderr cannot block stdout processing")
        try script("printf 'missing input\\n' >&2; exit 1")
        do {
            _ = try await SyncTeXService.forward(line: 9, file: source, pdf: pdf, executable: executable.path)
            fatalError("FAILED: failed commands need a reason")
        } catch SyncTeXService.Failure.commandFailed(let message) {
            check(message == "missing input", "command failures preserve a concise reason")
        }
        try script("exec 1>&- 2>&-; while :; do :; done")
        var heartbeat = false
        let tick = Task { @MainActor in
            try await Task.sleep(nanoseconds: 40_000_000)
            heartbeat = true
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await SyncTeXService.forward(line: 9, file: source, pdf: pdf, executable: executable.path, timeout: 0.15)
            fatalError("FAILED: closed-output commands must still time out")
        } catch SyncTeXService.Failure.timedOut { checks += 1 }
        _ = try await tick.value
        check(ProcessInfo.processInfo.systemUptime - started < 1.5, "timeout bounds the subprocess lifetime")
        check(heartbeat, "lookup keeps the main actor responsive")
        try script("while :; do :; done")
        let task = Task { try await SyncTeXService.forward(line: 9, file: source, pdf: pdf, executable: executable.path, timeout: 5) }
        try await Task.sleep(nanoseconds: 40_000_000)
        task.cancel()
        do {
            _ = try await task.value
            fatalError("FAILED: cancelled lookups must stop")
        } catch is CancellationError { checks += 1 }
        try FileManager.default.removeItem(at: syncData)
        do {
            _ = try await SyncTeXService.forward(line: 9, file: source, pdf: pdf, executable: executable.path)
            fatalError("FAILED: missing SyncTeX data needs a clear reason")
        } catch SyncTeXService.Failure.missingSyncData { checks += 1 }
        check(SyncTeXService.Failure.noMatch.localizedDescription.contains("Rebuild"), "unmatched positions provide a useful next action")
        print("PASS: \(checks) SyncTeX assertions")
    }
}
