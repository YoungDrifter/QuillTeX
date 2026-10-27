import Foundation
import CoreGraphics
import Darwin

/// Source ↔ PDF lookups run off the main thread, with a bounded process lifetime.
enum SyncTeXService {
    struct ForwardResult {
        var page: Int
        /// Origin of the enclosing box, measured from the page's upper-left corner.
        var point: CGPoint
        var width: CGFloat
        var height: CGFloat
    }

    struct InverseResult {
        var file: URL
        var line: Int
        var column: Int?
    }

    enum Failure: LocalizedError, Equatable {
        case missingPDF, missingSyncData, unavailableTool, timedOut, noMatch, invalidResult
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingPDF: return "Build the document before locating it in the PDF."
            case .missingSyncData: return "SyncTeX data is missing. Rebuild the document to enable source–PDF navigation."
            case .unavailableTool: return "The SyncTeX tool is unavailable. Check the TeX installation."
            case .timedOut: return "SyncTeX took too long. Try locating the position again."
            case .noMatch: return "No matching position was found. Rebuild the document if the source has changed."
            case .invalidResult: return "SyncTeX returned an invalid position. Rebuild the document and try again."
            case .commandFailed(let detail): return detail.isEmpty ? "SyncTeX could not locate this position." : "SyncTeX could not locate this position: \(detail)"
            }
        }
    }

    static func forward(line: Int, column: Int = 0, file: URL, pdf: URL,
                        executable: String, timeout: TimeInterval = 3) async throws -> ForwardResult {
        try validate(pdf: pdf, executable: executable)
        let output = try await run(executable, ["view", "-i", "\(max(line, 1)):\(max(column, 0)):\(file.path)", "-o", pdf.path], timeout: timeout)
        return try parseForward(output)
    }

    static func inverse(page: Int, x: CGFloat, y: CGFloat, pdf: URL,
                        executable: String, sourceDirectory: URL? = nil,
                        timeout: TimeInterval = 3) async throws -> InverseResult {
        try validate(pdf: pdf, executable: executable)
        guard page > 0, x.isFinite, y.isFinite else { throw Failure.invalidResult }
        let output = try await run(executable, ["edit", "-o", "\(page):\(x):\(y):\(pdf.path)"], timeout: timeout)
        return try parseInverse(output, pdf: pdf, sourceDirectory: sourceDirectory)
    }

    static func parseForward(_ output: String) throws -> ForwardResult {
        let fields = try parse(output)
        guard let page = fields["Page"].flatMap(Int.init), page > 0,
              let x = fields["h"].flatMap(Double.init) ?? fields["x"].flatMap(Double.init),
              let y = fields["v"].flatMap(Double.init) ?? fields["y"].flatMap(Double.init),
              x.isFinite, y.isFinite else { throw Failure.invalidResult }
        let width = fields["W"].flatMap(Double.init) ?? 0
        let height = fields["H"].flatMap(Double.init) ?? 0
        return ForwardResult(page: page, point: CGPoint(x: x, y: y),
                             width: width.isFinite ? abs(width) : 0,
                             height: height.isFinite ? abs(height) : 0)
    }

    static func parseInverse(_ output: String, pdf: URL, sourceDirectory: URL? = nil) throws -> InverseResult {
        let fields = try parse(output)
        guard let input = fields["Input"], let line = fields["Line"].flatMap(Int.init), line > 0 else { throw Failure.invalidResult }
        let url = input.hasPrefix("/") ? URL(fileURLWithPath: input)
            : URL(fileURLWithPath: input, relativeTo: sourceDirectory ?? pdf.deletingLastPathComponent())
        let column = fields["Column"].flatMap(Int.init)
        return InverseResult(file: url.standardizedFileURL, line: line,
                             column: column.flatMap { $0 > 0 ? $0 : nil })
    }

    private static func validate(pdf: URL, executable: String) throws {
        guard FileManager.default.fileExists(atPath: pdf.path) else { throw Failure.missingPDF }
        let stem = pdf.deletingPathExtension()
        guard [stem.appendingPathExtension("synctex"), stem.appendingPathExtension("synctex.gz")]
            .contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw Failure.missingSyncData }
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw Failure.unavailableTool }
    }

    /// The first record is SyncTeX's closest match; never mix fields across records.
    private static func parse(_ output: String) throws -> [String: String] {
        var fields: [String: String] = [:]
        var inside = false
        for line in output.split(separator: "\n") {
            if line.contains("SyncTeX result begin") { inside = true; continue }
            if line.contains("SyncTeX result end") { break }
            guard inside, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if fields[key] != nil { break }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { fields[key] = value }
        }
        guard inside else { throw Failure.noMatch }
        return fields
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runProcess(executable, arguments, timeout: timeout, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private static func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                                   cancellation: Cancellation) throws -> String {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "SYNCTEX_VIEWER")
        environment.removeValue(forKey: "SYNCTEX_EDITOR")
        process.environment = environment
        // Drain both streams together: an unusually verbose error cannot fill a
        // second pipe and deadlock the process while stdout is being consumed.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        defer { try? pipe.fileHandleForReading.close() }
        do { try process.run() } catch { throw Failure.commandFailed(error.localizedDescription) }
        try? pipe.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var finishedReading = false
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        while true {
            let cancelled = cancellation.isCancelled
            if cancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                stop(process)
                if cancelled { throw CancellationError() }
                throw Failure.timedOut
            }
            if finishedReading {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let available = poll(&pollDescriptor, 1, 50)
            if available > 0, pollDescriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                let count = read(descriptor, &buffer, buffer.count)
                if count == 0 { finishedReading = true; continue }
                if count > 0, output.count < 1_048_576 { output.append(contentsOf: buffer.prefix(min(count, 1_048_576 - output.count))) }
                if count < 0, errno != EINTR { stop(process); throw Failure.commandFailed("Unable to read the lookup result.") }
            } else if available < 0, errno != EINTR {
                stop(process)
                throw Failure.commandFailed("Unable to read the lookup result.")
            }
            if !process.isRunning, available == 0 { break }
        }
        process.waitUntilExit()
        if cancellation.isCancelled { throw CancellationError() }
        let text = String(data: output, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = text.split(separator: "\n").last.map(String.init) ?? ""
            throw Failure.commandFailed(String(detail.prefix(240)))
        }
        return text
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // A broken command that ignores SIGTERM must not keep a lookup alive.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
