import Foundation
import CoreGraphics

/// Source ↔ PDF lookups through the `synctex` command line tool that ships with TeX
/// Live. Keeping it out of process means the app never has to parse the compressed
/// SyncTeX file format itself.
enum SyncTeXService {
    struct ForwardResult {
        var page: Int
        /// Point in PDF page space with a top-left origin, as synctex reports it.
        var point: CGPoint
        var width: CGFloat
        var height: CGFloat
    }

    struct InverseResult {
        var file: URL
        var line: Int
        var column: Int?
    }

    /// Where the PDF's kind of edit happens for a source position.
    static func forward(line: Int, column: Int = 0, file: URL, pdf: URL, executable: String) -> ForwardResult? {
        let output = run(executable, ["view", "-i", "\(line):\(max(column, 0)):\(file.path)", "-o", pdf.path])
        guard output.contains("SyncTeX result begin") else { return nil }
        let fields = parse(output)
        guard let page = fields["Page"].flatMap(Int.init),
              let x = fields["x"].flatMap(Double.init),
              let y = fields["y"].flatMap(Double.init) else { return nil }
        return ForwardResult(page: page,
                             point: CGPoint(x: x, y: y),
                             width: fields["W"].flatMap(Double.init) ?? 0,
                             height: fields["H"].flatMap(Double.init) ?? 0)
    }

    /// Which source line a click in the PDF belongs to.
    static func inverse(page: Int, x: CGFloat, y: CGFloat, pdf: URL, executable: String) -> InverseResult? {
        let output = run(executable, ["edit", "-o", "\(page):\(Int(x)):\(Int(y)):\(pdf.path)"])
        guard output.contains("SyncTeX result begin") else { return nil }
        let fields = parse(output)
        guard let input = fields["Input"], let line = fields["Line"].flatMap(Int.init), line > 0 else { return nil }
        let url = input.hasPrefix("/")
            ? URL(fileURLWithPath: input)
            : URL(fileURLWithPath: input, relativeTo: pdf.deletingLastPathComponent())
        return InverseResult(file: url.standardizedFileURL, line: line, column: fields["Column"].flatMap(Int.init))
    }

    /// `Key:value` pairs between the `SyncTeX result begin/end` markers.
    private static func parse(_ output: String) -> [String: String] {
        var fields: [String: String] = [:]
        var inside = false
        for line in output.split(separator: "\n") {
            if line.contains("SyncTeX result begin") { inside = true; continue }
            if line.contains("SyncTeX result end") { break }
            guard inside, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if fields[key] == nil, !value.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
