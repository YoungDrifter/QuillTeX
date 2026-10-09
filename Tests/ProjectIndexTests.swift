import Foundation

@main
struct ProjectIndexTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuillTeX-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ path: String, _ content: String) throws -> URL {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAILED: \(message)") }
            assertions += 1
        }
        func flat(_ nodes: [NavigationNode]) -> [NavigationNode] { nodes.flatMap { [$0] + flat($0.children) } }
        let root = try write("main.tex", #"""
        \documentclass{ctexart}
        \graphicspath{{images/}}
        \begin{document}
        % \section{Ignored}
        \section{基础}
        \input{chapters/中文 文件}
        \section*{Conclusion}
        \includegraphics{plot}
        \pgfplotstableread{data/table.csv}\table
        \input{missing}
        \includegraphics{\dynamicpath}
        \begin{verbatim}
        \section{Also ignored}
        \input{fake}
        \end{verbatim}
        \end{document}
        """#)
        let childText = #"""
        % !TeX root = ../main.tex
        \subsection{中文与 emoji 😀}
        \label{中文_label}
        正文 hello world $hidden maths$。
        \input{../main}
        """#
        let child = try write("chapters/中文 文件.tex", childText)
        _ = try write("images/plot.pdf", "fixture")
        _ = try write("data/table.csv", "x,y\n1,2")
        _ = try write("unused.tex", "unused")
        _ = try write("build/generated.tex", "exclude")
        _ = try write(".hidden/secret.tex", "exclude")
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).tex")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.tex"), withDestinationURL: outside)
        let index = ProjectIndexer(root: root, overrides: [:]).build()
        let headings = flat(index.structure).filter { $0.kind == .section }
        check(headings.map(\.title) == ["基础", "中文与 emoji 😀", "Conclusion"], "source order across includes, comments and verbatim")
        check(headings.first?.children.first?.title == "中文与 emoji 😀", "section hierarchy")
        let label = flat(index.structure).first { $0.kind == .label }!
        check(label.url == child, "cross-file label URL")
        check((childText as NSString).substring(from: label.offset).hasPrefix(#"\label"#), "UTF-16 label location after emoji")
        check(index.issues.contains { $0.contains("Circular reference") }, "cycle detection")
        check(index.issues.contains { $0.contains("missing") }, "missing include")
        check(index.issues.contains { $0.contains("dynamic reference") }, "dynamic resource")
        check(index.texFiles.count == 3, "picker excludes hidden, build, outside symlinks")
        check(index.texFiles.contains { $0.lastPathComponent == "unused.tex" }, "folder includes unreferenced source")
        check(!ProjectIndexer.isWithin(outside, directory: directory), "containment boundary")
        check(ProjectIndexer.rootDirective(in: childText) == "../main.tex", "root directive")
        check(ProjectIndexer.isMainDocument(try! String(contentsOf: root, encoding: .utf8), at: root), "documentclass identifies the main file")
        check(!ProjectIndexer.isMainDocument(childText, at: child), "input child is not a main file")
        check(!ProjectIndexer.isMainDocument("% \\documentclass{article}\nJust text", at: child), "commented documentclass cannot make a main file")
        check(!ProjectIndexer.isMainDocument("\\documentclass[../main.tex]{subfiles}", at: child), "subfiles package child is not a main file")
        check(!ProjectIndexer.isMainDocument("% !TeX root = ../main.tex\n\\documentclass{article}", at: child), "different root directive identifies a child")
        check(ProjectIndexer.isMainDocument("% !TeX root = main.tex\n\\documentclass [a4paper] {article}", at: root), "self root and spaced class are accepted")
        check(!index.issues.contains { $0.contains("plot") }, "graphicspath resolution")
        check(!index.issues.contains { $0.contains("table.csv") }, "table resource")
        check(!flat(index.subfiles).contains { $0.url == root }, "Subfiles excludes main file, including cyclic links")
        check(index.subfiles.first?.url == child, "Subfiles begins directly with referenced child")
        check(flat(index.subfiles).allSatisfy { $0.kind == .source }, "Subfiles only includes source files")
        // A file the process may not read is reported as a permission problem, not as missing.
        let locked = try write("locked.tex", "\\section{Locked}\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let lockedRoot = try write("locked-main.tex", "\\documentclass{article}\n\\begin{document}\n\\input{locked.tex}\n\\end{document}\n")
        let lockedIndex = ProjectIndexer(root: lockedRoot, overrides: [:]).build()
        check(lockedIndex.issues.contains { $0.contains("No permission:") }, "unreadable file reported as a permission problem")
        check(!lockedIndex.issues.contains { $0.contains("Missing:") }, "permission failure is not reported as a missing file")
        check(flat(lockedIndex.subfiles).contains { $0.detail == "No permission to read" }, "node carries the permission detail")
        let override = childText.replacingOccurrences(of: "中文与 emoji 😀", with: "未保存标题")
        let edited = ProjectIndexer(root: root, overrides: [child: override]).build()
        check(flat(edited.structure).contains { $0.title == "未保存标题" }, "unsaved buffer indexing")
        let masked = ProjectIndexer.masked("😀 % 😀\r\n\\section{real}")
        check((masked as NSString).length == ("😀 % 😀\r\n\\section{real}" as NSString).length, "mask preserves UTF-16 offsets")
        check(masked.contains("\r\n"), "mask preserves CRLF")
        // Figures and tables become Structure entries with their caption and label.
        let floats = ProjectIndexer.floats(in: """
        \\begin{figure}[htbp]
          \\includegraphics[width=.8\\textwidth]{figures/wave.pdf}
          \\caption{一维波动方程}
          \\label{fig:wave}
        \\end{figure}
        \\begin{table}
          \\caption{Numerical results}
          \\label{tab:results}
        \\end{table}
        \\includegraphics{figures/loose.png}
        """, file: URL(fileURLWithPath: "/tmp/project/main.tex"))
        check(floats.figures.count == 1, "a figure environment is collected once")
        check(floats.figures.first?.title == "一维波动方程", "the caption becomes the figure title")
        check(floats.figures.first?.detail == "fig:wave", "the figure keeps its label")
        check(floats.figures.first?.kind == .figure, "figures carry their own kind")
        check(floats.tables.count == 1 && floats.tables.first?.title == "Numerical results", "a table keeps its caption")
        check(floats.tables.first?.detail == "tab:results", "the table keeps its label")
        check(ProjectIndexer.floats(in: "", file: URL(fileURLWithPath: "/tmp/main.tex")).figures.isEmpty,
              "a document without floats reports none")

        // A document without floats still lists both groups, with a zero count.
        let plain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quilltex-plain-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let plainMain = plain.appendingPathComponent("main.tex")
        try? "\\documentclass{article}\n\\begin{document}\nhi\n\\end{document}\n".write(to: plainMain, atomically: true, encoding: .utf8)
        let plainIndex = ProjectIndexer(root: plainMain, overrides: [:]).build()
        check(plainIndex.structure.map(\.title).contains("Figures"), "Figures is listed even without figures")
        check(plainIndex.structure.first { $0.title == "Figures" }?.count == 0, "an empty Figures group counts zero")
        check(plainIndex.structure.first { $0.title == "Tables" }?.count == 0, "an empty Tables group counts zero")
        check(plainIndex.structure.first { $0.title == "Labels" }?.count == 0, "an empty Labels group counts zero")
        try? FileManager.default.removeItem(at: plain)

        print("PASS: \(assertions) project-index assertions")
    }
}
