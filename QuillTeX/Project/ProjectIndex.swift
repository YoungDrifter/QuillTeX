import Foundation

struct NavigationNode: Identifiable, Sendable {
    enum Kind: String, Sendable { case group, section, label, source, resource, folder, boundary, issue, figure, table }
    let id: String
    var title: String
    var kind: Kind
    var url: URL?
    var offset: Int = 0 // UTF-16 offsets match NSTextView and NSRange.
    var children: [NavigationNode] = []
    var detail: String? = nil
    var count: Int? = nil
    var isMissing: Bool = false
}

struct ProjectIndex: Sendable {
    var structure: [NavigationNode] = []
    var subfiles: [NavigationNode] = []
    var folders: [NavigationNode] = []
    var texFiles: [URL] = []
    /// Floats, in document order, for the Structure view.
    var figures: [NavigationNode] = []
    var tables: [NavigationNode] = []
    /// Label names (`\label{...}`) and BibTeX keys, offered by the editor's completion.
    var labels: [String] = []
    var citations: [String] = []
    var issues: [String] = []
}

struct ProjectIndexer {
    let root: URL
    let overrides: [URL: String]
    private var directory: URL { root.deletingLastPathComponent() }

    static func isWithin(_ url: URL, directory: URL) -> Bool {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Mask ignored regions without shifting any UTF-16 source positions.
    static func masked(_ text: String) -> String {
        let string = NSMutableString(string: text)
        let pattern = #"(?s)\\begin\{(verbatim\*?|Verbatim|lstlisting|minted|comment)\}.*?\\end\{\1\}|\\verb\*?([^\w\s]).*?\2|(?m)(?<!\\)%[^\r\n]*"#
        for match in matches(pattern, in: text).reversed() {
            let original = (text as NSString).substring(with: match.range)
            let replacement = original.utf16.map { ($0 == 10 || $0 == 13) ? String(UnicodeScalar(Int($0))!) : " " }.joined()
            string.replaceCharacters(in: match.range, with: replacement)
        }
        return string as String
    }

    /// Keys declared in a BibTeX file, in the order they appear.
    /// Figures and tables: an environment, its caption and its label. LaTeX lets the
    /// caption come before or after the label, so both are looked up inside the block.
    static func floats(in text: String, file: URL) -> (figures: [NavigationNode], tables: [NavigationNode]) {
        let masked = masked(text)
        let ns = masked as NSString
        var figures: [NavigationNode] = []
        var tables: [NavigationNode] = []
        for match in matches(#"(?s)\\begin\{(figure\*?|table\*?)\}(.*?)\\end\{\1\}"#, in: masked) {
            let environment = ns.substring(with: match.range(at: 1))
            let body = ns.substring(with: match.range(at: 2))
            let isFigure = environment.hasPrefix("figure")
            var title: String?
            if let caption = matches(#"\\caption(?:\[[^\]]*\])?\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}"#, in: body).first {
                title = (body as NSString).substring(with: caption.range(at: 1))
            }
            if title == nil, let graphic = matches(#"\\includegraphics(?:\[[^\]]*\])?\{([^}]*)\}"#, in: body).first {
                title = ((body as NSString).substring(with: graphic.range(at: 1)) as NSString).lastPathComponent
            }
            var label: String?
            if let found = matches(#"\\label\{([^}]*)\}"#, in: body).first {
                label = (body as NSString).substring(with: found.range(at: 1))
            }
            let node = NavigationNode(id: "\(file.path):\(match.range.location):\(environment)",
                                      title: title ?? (isFigure ? "Figure" : "Table"),
                                      kind: isFigure ? .figure : .table,
                                      url: file,
                                      offset: match.range.location,
                                      detail: label)
            if isFigure { figures.append(node) } else { tables.append(node) }
        }
        return (figures, tables)
    }

    static func citationKeys(in text: String) -> [String] {
        var keys: [String] = []
        for match in matches(#"(?m)^\s*@[A-Za-z]+\s*[({]\s*([^,\s})]+)"#, in: text) {
            let key = (text as NSString).substring(with: match.range(at: 1))
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// Recognise standalone documents, while keeping subfiles-package children
    /// and files pointing at a different root out of the project entry points.
    static func isMainDocument(_ text: String, at url: URL) -> Bool {
        if let directive = rootDirective(in: text) {
            let declared = URL(fileURLWithPath: directive, relativeTo: url.deletingLastPathComponent())
            if declared.standardizedFileURL != url.standardizedFileURL { return false }
        }
        let clean = masked(text)
        guard let match = matches(#"\\documentclass\s*(?:\[[^\]]*\]\s*)?\{([^{}]+)\}"#, in: clean).first else { return false }
        let name = (clean as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name != "subfiles"
    }

    static func rootDirective(in text: String) -> String? {
        guard let match = matches(#"(?im)^\s*%\s*!\s*tex\s+root\s*=\s*(.+?)\s*$"#, in: text).first else { return nil }
        return (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why a source file could not be turned into text. Missing and unreadable files
    /// are reported apart: macOS refuses reads in protected folders, and that is a
    /// permission problem the user can fix, not a missing file.
    enum SourceRead {
        case text(String)
        case missing
        case unreadable
        case denied
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == NSFileReadNoPermissionError || code == EACCES || code == EPERM
    }

    func build() -> ProjectIndex {
        var result = ProjectIndex()
        var visited = Set<URL>()
        var outline: [(level: Int, node: NavigationNode)] = []
        var labels: [NavigationNode] = []
        var figures: [NavigationNode] = []
        var tables: [NavigationNode] = []
        var graphicPaths: [URL] = [directory]
        let levels = ["part": 0, "chapter": 1, "section": 2, "subsection": 3, "subsubsection": 4]

        func read(_ url: URL) -> SourceRead {
            if let override = overrides[url.standardizedFileURL] { return .text(override) }
            do { return .text(try String(contentsOf: url, encoding: .utf8)) }
            catch {
                if Self.isPermissionError(error) { return .denied }
                return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
            }
        }
        func resolve(_ value: String, from file: URL, extensions: [String], graphics: Bool = false) -> URL? {
            guard !value.contains("\\"), !value.contains("#") else { return nil }
            let bases = [file.deletingLastPathComponent(), directory] + (graphics ? graphicPaths : [])
            for base in bases {
                let candidate = (value.hasPrefix("/") ? URL(fileURLWithPath: value) : base.appendingPathComponent(value)).standardizedFileURL
                let variants = candidate.pathExtension.isEmpty ? [candidate] + extensions.map { candidate.appendingPathExtension($0) } : [candidate]
                if let found = variants.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return found }
            }
            return nil
        }
        func visit(_ input: URL, ancestry: Set<URL>) -> NavigationNode {
            let file = input.standardizedFileURL
            let identity = file.resolvingSymlinksInPath()
            var node = NavigationNode(id: "source:\(file.path)", title: file.lastPathComponent, kind: .source, url: file, detail: file == root ? "ROOT" : nil)
            if ancestry.contains(identity) {
                node.detail = "Circular reference"
                result.issues.append("Circular reference: \(file.lastPathComponent)")
                return node
            }
            // Duplicate inclusions remain visible, but do not duplicate structure or statistics.
            if visited.contains(identity) { node.detail = "Duplicate inclusion"; return node }
            let source: String
            switch read(file) {
            case .text(let text):
                source = text
            case .denied:
                node.isMissing = true; node.detail = "No permission to read"
                result.issues.append("No permission: \(file.path)"); return node
            case .missing:
                node.isMissing = true; node.detail = "File not found"
                result.issues.append("Missing: \(file.path)"); return node
            case .unreadable:
                node.isMissing = true; node.detail = "Cannot be read as UTF-8"
                result.issues.append("Cannot read: \(file.path)"); return node
            }
            visited.insert(identity)
            let floats = Self.floats(in: source, file: file)
            figures.append(contentsOf: floats.figures)
            tables.append(contentsOf: floats.tables)
            let clean = Self.masked(source)
            let ns = clean as NSString
            for paths in Self.matches(#"\\graphicspath\s*\{((?:\s*\{[^}]*\}\s*)+)\}"#, in: clean) {
                for path in Self.matches(#"\{([^}]*)\}"#, in: ns.substring(with: paths.range(at: 1))) {
                    let inner = ns.substring(with: paths.range(at: 1)) as NSString
                    graphicPaths.append(file.deletingLastPathComponent().appendingPathComponent(inner.substring(with: path.range(at: 1))))
                }
            }
            let pattern = #"\\(part|chapter|section|subsection|subsubsection|label|input|include|includegraphics|pgfplotstableread|csvreader|begin|end)\*?\s*(?:\[[^\]]*\]\s*)?\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}|\\addplot\+?\s*(?:\[[^\]]*\]\s*)?table\s*(?:\[[^\]]*\]\s*)?\{([^}]*)\}|\\input\s+([^\s{}%]+)"#
            for match in Self.matches(pattern, in: clean) {
                let command = match.range(at: 1).location == NSNotFound ? (match.range(at: 3).location == NSNotFound ? "input" : "table") : ns.substring(with: match.range(at: 1))
                let argRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : (match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 4))
                let value = ns.substring(with: argRange).trimmingCharacters(in: .whitespacesAndNewlines)
                let id = "\(file.path):\(match.range.location):\(command)"
                if let level = levels[command] {
                    let title = value.replacingOccurrences(of: #"\\[A-Za-z]+"#, with: "", options: .regularExpression).replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                    outline.append((level, NavigationNode(id: id, title: title, kind: .section, url: file, offset: match.range.location)))
                } else if command == "label" {
                    labels.append(NavigationNode(id: id, title: value, kind: .label, url: file, offset: match.range.location))
                } else if command == "begin" || command == "end" {
                    if value == "document" { outline.append((-1, NavigationNode(id: id, title: command == "begin" ? "Begin Document" : "End Document", kind: .boundary, url: file, offset: match.range.location))) }
                } else {
                    let isSource = command == "input" || command == "include"
                    let extensions = isSource ? ["tex"] : (command == "includegraphics" ? ["pdf", "png", "jpg", "jpeg", "eps"] : ["csv", "tsv", "dat", "txt"])
                    if let url = resolve(value, from: file, extensions: extensions, graphics: command == "includegraphics") {
                        if isSource {
                            var child = visit(url, ancestry: ancestry.union([identity]))
                            child = reidentify(child, prefix: id)
                            node.children.append(child)
                        } else {
                            node.children.append(NavigationNode(id: id, title: url.lastPathComponent, kind: .resource, url: url))
                        }
                    } else {
                        let dynamic = value.contains("\\") || value.contains("#")
                        node.children.append(NavigationNode(id: id, title: value, kind: .issue, url: file, offset: match.range.location, detail: dynamic ? "Dynamic path, cannot be resolved statically" : "File not found", isMissing: true))
                        result.issues.append("\(file.lastPathComponent): \(dynamic ? "dynamic reference" : "missing reference") \(value)")
                    }
                }
            }
            return node
        }
        func reidentify(_ node: NavigationNode, prefix: String) -> NavigationNode {
            NavigationNode(id: prefix + ":" + node.id, title: node.title, kind: node.kind, url: node.url, offset: node.offset, children: node.children.map { reidentify($0, prefix: prefix) }, detail: node.detail, count: node.count, isMissing: node.isMissing)
        }
        let rootNode = visit(root, ancestry: [])
        func subfilesOnly(_ nodes: [NavigationNode]) -> [NavigationNode] {
            nodes.filter { $0.kind == .source && $0.url != root }.map { node in
                var child = node; child.children = subfilesOnly(node.children); return child
            }
        }
        result.subfiles = subfilesOnly(rootNode.children)
        var position = 0
        func hierarchy(parentLevel: Int) -> [NavigationNode] {
            var children: [NavigationNode] = []
            while position < outline.count {
                let item = outline[position]
                if item.level <= parentLevel { break }
                position += 1
                var node = item.node
                if item.level >= 0 { node.children = hierarchy(parentLevel: item.level) }
                children.append(node)
            }
            return children
        }
        // Every group is always listed — Table of Contents, Labels, Figures, Tables — so
        // the structure of the document is visible even where a group is empty.
        result.structure = [
            NavigationNode(id: "contents", title: "Table of Contents", kind: .group, children: hierarchy(parentLevel: -2), count: outline.filter { $0.level >= 0 }.count)
        ]
        result.structure.append(NavigationNode(id: "labels", title: "Labels", kind: .group, children: labels, count: labels.count))
        // Figures and Tables join the list on the same rule; their count just reads zero.
        result.structure.append(NavigationNode(id: "figures", title: "Figures", kind: .group, children: figures, count: figures.count))
        result.structure.append(NavigationNode(id: "tables", title: "Tables", kind: .group, children: tables, count: tables.count))
        result.figures = figures
        result.tables = tables
        var seenDirectories = Set<URL>()
        func folder(_ url: URL) -> NavigationNode {
            var node = NavigationNode(id: "folder:\(url.path)", title: url.lastPathComponent, kind: .folder, url: url)
            let resolved = url.resolvingSymlinksInPath()
            guard seenDirectories.insert(resolved).inserted else { return node }
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for child in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard child.lastPathComponent != "build", Self.isWithin(child, directory: directory) else { continue }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDirectory { node.children.append(folder(child)) }
                else {
                    let tex = child.pathExtension.lowercased() == "tex"
                    if tex { result.texFiles.append(child.standardizedFileURL) }
                    node.children.append(NavigationNode(id: "file:\(child.path)", title: child.lastPathComponent, kind: tex ? .source : .resource, url: child.standardizedFileURL))
                }
            }
            return node
        }
        result.folders = [folder(directory)]
        result.labels = labels.map(\.title).sorted()
        // Citation keys, so \cite{...} can complete. Bounded to the project folder and
        // skipped when the folder is somewhere huge like the home directory.
        let home = NSHomeDirectory()
        if directory.path != "/" && directory.path != home,
           let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var found: [String] = []
            var seenFiles = 0
            for case let url as URL in walker where url.pathExtension.lowercased() == "bib" {
                seenFiles += 1
                if seenFiles > 200 { break }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for key in Self.citationKeys(in: text) where !found.contains(key) { found.append(key) }
            }
            result.citations = found.sorted()
        }
        return result
    }
}
