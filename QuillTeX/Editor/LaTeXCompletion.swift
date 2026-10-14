import Foundation
import AppKit

/// What the editor offers in its completion popup.
///
/// Commands, environments and packages come from the bundled lists; labels and
/// citation keys come from the project index. The rules are pure so they can be
/// tested without a window or a text view.
enum LaTeXCompletion {
    enum Context: Equatable, Sendable {
        case command        // \sec…
        case environment    // \begin{it…
        case endEnvironment // \end{it… only completes the name
        case package        // \usepackage{am…
        case label          // \ref{… \eqref{… \cref{…
        case citation       // \cite{… \cite[p. 3]{…
    }

    /// Where the popup applies and what has been typed so far.
    struct Suggestion: Equatable, Sendable {
        var context: Context
        /// Characters the chosen candidate replaces.
        var range: NSRange
        /// The typed text inside `range`.
        var prefix: String
    }

    // MARK: - Deciding what is being typed

    static func suggestion(in text: String, at offset: Int) -> Suggestion? {
        let ns = text as NSString
        let limit = min(max(0, offset), ns.length)
        let word = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@*")
        var start = limit
        while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)), word.contains(scalar) {
            start -= 1
        }
        let result: Suggestion
        if start > 0, ns.character(at: start - 1) == backslash, !escaped(start - 1, in: ns) {
            var end = limit
            while end < ns.length, let scalar = UnicodeScalar(ns.character(at: end)), word.contains(scalar) { end += 1 }
            result = Suggestion(context: .command,
                                range: NSRange(location: start - 1, length: end - start + 1),
                                prefix: ns.substring(with: NSRange(location: start - 1, length: limit - start + 1)))
        } else {
            // Keys are not command words: punctuation and Unicode belong to the key.
            // Only the current comma-delimited argument is replaced.
            var brace = limit
            while brace > 0 {
                brace -= 1
                let unit = ns.character(at: brace)
                if unit == openBrace, !escaped(brace, in: ns) { break }
                if unit == 0x7D || unit == backslash { return nil }
            }
            guard brace < limit, ns.character(at: brace) == openBrace,
                  let name = command(before: brace, in: ns) else { return nil }
            let context: Context
            switch name {
            case "begin": context = .environment
            case "end": context = .endEnvironment
            case "usepackage", "documentclass": context = .package
            case "ref", "eqref", "pageref", "autoref", "cref", "Cref", "label": context = .label
            case "cite", "citep", "citet", "citealp", "parencite", "textcite", "autocite", "footcite", "nocite": context = .citation
            default: return nil
            }
            start = brace + 1
            for position in start..<limit where ns.character(at: position) == 0x2C { start = position + 1 }
            while start < limit, isWhitespace(ns.character(at: start)) { start += 1 }
            let prefix = ns.substring(with: NSRange(location: start, length: limit - start))
            guard !prefix.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else { return nil }
            var end = limit
            while end < ns.length {
                let unit = ns.character(at: end)
                if unit == 0x2C || unit == 0x7D || unit == openBrace || unit == backslash || isWhitespace(unit) { break }
                end += 1
            }
            result = Suggestion(context: context, range: NSRange(location: start, length: end - start), prefix: prefix)
        }
        // The same lexer used by highlighting excludes comments and literal regions.
        // UI callers evaluate this pure function on a background task.
        let prefix = ns.substring(to: limit)
        let excluded = LaTeXHighlighter.spans(in: prefix).filter { $0.token == .comment || $0.token == .verbatim }
        let checkedStart = result.prefix.isEmpty ? max(0, result.range.location - 1) : result.range.location
        let checkedRange = NSRange(location: checkedStart, length: max(1, limit - checkedStart))
        guard !excluded.contains(where: { NSIntersectionRange($0.range, checkedRange).length > 0 }) else { return nil }
        return result
    }

    // MARK: - Candidates

    static func candidates(for suggestion: Suggestion, labels: [String], citations: [String],
                           projectCommands: [String] = [], projectEnvironments: [String] = []) -> [String] {
        let pool: [String]
        switch suggestion.context {
        case .command: pool = commands + projectCommands
        case .environment, .endEnvironment: pool = environments + projectEnvironments
        case .package: pool = packages
        case .label: pool = labels
        case .citation: pool = citations
        }
        // Commands carry their backslash, the typed text does not: compare without it.
        func key(_ value: String) -> String {
            (value.hasPrefix("\\") ? String(value.dropFirst()) : value).lowercased()
        }
        let needle = key(suggestion.prefix)
        return Array(Set(pool))
            .filter { needle.isEmpty || key($0).contains(needle) }
            .sorted { first, second in
                let a = key(first), b = key(second)
                let firstStarts = a.hasPrefix(needle), secondStarts = b.hasPrefix(needle)
                if firstStarts != secondStarts { return firstStarts }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
    }

    /// UTF-16 ranges identify editable arguments; no placeholder text enters the file.
    struct Insertion: Equatable, Sendable {
        var range: NSRange
        var text: String
        var placeholders: [NSRange] = []
        var finalOffset: Int
    }

    static func insertion(for candidate: String, suggestion: Suggestion, in source: String) -> Insertion {
        let ns = source as NSString
        var range = suggestion.range
        var text = candidate
        var placeholders: [NSRange] = []
        let next = NSMaxRange(range)
        let hasBrace = next < ns.length && ns.character(at: next) == 0x7D
        if suggestion.context == .environment || suggestion.context == .endEnvironment {
            if hasBrace { range.length += 1 }
            text += "}"
            if suggestion.context == .environment {
                let closing = "\\end{\(candidate)}"
                let tail = ns.substring(from: NSMaxRange(range))
                // Complete an existing environment without creating a second closing pair.
                if !tail.contains(closing) {
                    let newline = source.contains("\r\n") ? "\r\n" : "\n"
                    text += newline
                    placeholders = [NSRange(location: text.utf16.count, length: 0)]
                    text += newline + closing
                }
            }
        } else if suggestion.context == .command,
                  !(next < ns.length && (ns.character(at: next) == openBrace || ns.character(at: next) == 0x5B)),
                  let arguments = commandArguments[candidate] {
            for _ in 0..<arguments {
                text += "{"
                placeholders.append(NSRange(location: text.utf16.count, length: 0))
                text += "}"
            }
        }
        return Insertion(range: range, text: text, placeholders: placeholders, finalOffset: text.utf16.count)
    }

    // MARK: - Popup items

    /// One row of the completion popup.
    struct Item: Equatable, Identifiable, Sendable {
        var id: String { title }
        var title: String
    }

    static func items(for suggestion: Suggestion, labels: [String], citations: [String],
                      projectCommands: [String] = [], projectEnvironments: [String] = []) -> [Item] {
        candidates(for: suggestion, labels: labels, citations: citations,
                   projectCommands: projectCommands, projectEnvironments: projectEnvironments)
            .map { Item(title: $0) }
    }

    /// How wide the popup should be for these rows: as wide as the longest candidate,
    /// inside bounds so a very long name cannot stretch the panel across the screen.
    static func panelWidth(for items: [Item]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let widest = items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // Row padding 9+9, container padding 5+5, selection slack.
        return min(440, max(196, max(widest, 96) + 46))
    }

    // MARK: - Inline hint

    /// The faint text drawn after the caret, and what Tab writes.
    struct Inline: Equatable, Sendable {
        /// The whole candidate, for example `\section`.
        var full: String
        /// Only the part still missing, for example `tion`.
        var remainder: String
        /// Characters the candidate replaces.
        var range: NSRange
        var context: Context
    }

    /// A hint is only offered when what has been typed is a genuine prefix of a
    /// candidate, so the ghost text never guesses. Very short command prefixes are
    /// skipped: after a lone `\` every command matches and a hint would be noise.
    static func inline(in text: String, at offset: Int, labels: [String], citations: [String],
                       projectCommands: [String] = [], projectEnvironments: [String] = []) -> Inline? {
        guard let suggestion = suggestion(in: text, at: offset) else { return nil }
        return inline(for: suggestion, labels: labels, citations: citations,
                      projectCommands: projectCommands, projectEnvironments: projectEnvironments)
    }

    static func inline(for suggestion: Suggestion, labels: [String], citations: [String],
                       projectCommands: [String] = [], projectEnvironments: [String] = []) -> Inline? {
        let typed = suggestion.prefix.hasPrefix("\\") ? String(suggestion.prefix.dropFirst()) : suggestion.prefix
        if suggestion.context == .command, typed.count < 2 { return nil }
        guard let best = candidates(for: suggestion, labels: labels, citations: citations,
                                    projectCommands: projectCommands, projectEnvironments: projectEnvironments).first else { return nil }
        let candidate = best.hasPrefix("\\") ? String(best.dropFirst()) : best
        guard candidate.lowercased().hasPrefix(typed.lowercased()), candidate.count > typed.count else { return nil }
        return Inline(full: best,
                      remainder: String(candidate.dropFirst(typed.count)),
                      range: suggestion.range,
                      context: suggestion.context)
    }

    // MARK: - Looking backwards

    private static let backslash = UInt16(0x5C)   // \
    private static let openBrace = UInt16(0x7B)   // {

    private static func isWhitespace(_ value: UInt16) -> Bool {
        UnicodeScalar(value).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
    }

    private static func escaped(_ index: Int, in ns: NSString) -> Bool {
        var cursor = index, count = 0
        while cursor > 0, ns.character(at: cursor - 1) == backslash { count += 1; cursor -= 1 }
        return count % 2 == 1
    }

    private static let commandArguments: [String: Int] = [
        "\\frac": 2, "\\dfrac": 2, "\\tfrac": 2, "\\sqrt": 1,
        "\\mathbb": 1, "\\mathcal": 1, "\\mathbf": 1, "\\mathrm": 1, "\\mathit": 1,
        "\\mathsf": 1, "\\mathfrak": 1, "\\boldsymbol": 1, "\\text": 1,
        "\\operatorname": 1, "\\overline": 1, "\\underline": 1, "\\hat": 1,
        "\\bar": 1, "\\vec": 1, "\\dot": 1, "\\ddot": 1, "\\tilde": 1,
        "\\widehat": 1, "\\widetilde": 1
    ]

    /// Command name ending just before `index`, skipping spaces and a bracket
    /// argument: `\cite[p. 3]{` gives "cite".
    private static func command(before index: Int, in ns: NSString) -> String? {
        var cursor = index
        func isSpace(_ value: UInt16) -> Bool {
            guard let scalar = UnicodeScalar(value) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        func skipSpaces() { while cursor > 0, isSpace(ns.character(at: cursor - 1)) { cursor -= 1 } }
        func matches(_ value: Character) -> Bool {
            guard let scalar = value.unicodeScalars.first else { return false }
            return cursor > 0 && ns.character(at: cursor - 1) == UInt16(scalar.value)
        }

        skipSpaces()
        // An optional argument may sit between the command and the brace: \cite[p. 3]{
        while matches("]") {
            var depth = 0
            while cursor > 0 {
                if matches("]") { depth += 1 }
                else if matches("[") {
                    depth -= 1
                    if depth == 0 { cursor -= 1; break }
                }
                cursor -= 1
            }
            skipSpaces()
        }
        // The command name, then the backslash that starts it.
        if matches("*") { cursor -= 1 }
        var nameEnd = cursor
        while nameEnd > 0, let scalar = UnicodeScalar(ns.character(at: nameEnd - 1)),
              CharacterSet.letters.contains(scalar) { nameEnd -= 1 }
        guard nameEnd < cursor, nameEnd > 0,
              ns.character(at: nameEnd - 1) == UInt16(0x5C) else { return nil }
        guard !escaped(nameEnd - 1, in: ns) else { return nil }
        let name = ns.substring(with: NSRange(location: nameEnd, length: cursor - nameEnd))
        return name.hasSuffix("*") ? String(name.dropLast()) : name
    }

    // MARK: - Bundled lists

    static let commands: [String] = [
        "\\documentclass", "\\usepackage", "\\begin", "\\end", "\\title", "\\author", "\\date", "\\maketitle",
        "\\tableofcontents", "\\section", "\\section*", "\\subsection", "\\subsection*", "\\subsubsection",
        "\\paragraph", "\\chapter", "\\part", "\\appendix", "\\label", "\\ref", "\\eqref", "\\pageref",
        "\\autoref", "\\cref", "\\Cref", "\\cite", "\\citep", "\\citet", "\\parencite", "\\textcite",
        "\\bibliography", "\\bibliographystyle", "\\addbibresource", "\\printbibliography", "\\input", "\\include",
        "\\includegraphics", "\\caption", "\\captionof", "\\centering", "\\item", "\\footnote", "\\marginpar",
        "\\emph", "\\textit", "\\textbf", "\\texttt", "\\textsf", "\\textsc", "\\underline", "\\textsuperscript",
        "\\textsubscript", "\\verb", "\\lstinline", "\\newpage", "\\clearpage", "\\linebreak", "\\newline",
        "\\noindent", "\\par", "\\hspace", "\\vspace", "\\hfill", "\\vfill", "\\quad", "\\qquad", "\\hrule",
        "\\hline", "\\toprule", "\\midrule", "\\bottomrule", "\\multicolumn", "\\multirow", "\\cline",
        "\\frac", "\\dfrac", "\\tfrac", "\\sqrt", "\\sum", "\\prod", "\\int", "\\iint", "\\oint", "\\lim",
        "\\log", "\\ln", "\\exp", "\\sin", "\\cos", "\\tan", "\\min", "\\max", "\\sup", "\\inf", "\\operatorname",
        "\\left", "\\right", "\\big", "\\Big", "\\bigl", "\\bigr", "\\cdot", "\\cdots", "\\ldots", "\\vdots",
        "\\times", "\\div", "\\pm", "\\mp", "\\leq", "\\geq", "\\neq", "\\approx", "\\equiv", "\\sim", "\\simeq",
        "\\propto", "\\in", "\\notin", "\\subset", "\\subseteq", "\\supset", "\\cup", "\\cap", "\\emptyset",
        "\\forall", "\\exists", "\\partial", "\\nabla", "\\infty", "\\to", "\\rightarrow", "\\Rightarrow",
        "\\leftrightarrow", "\\mapsto", "\\langle", "\\rangle", "\\lvert", "\\rvert", "\\lVert", "\\rVert",
        "\\mathbb", "\\mathcal", "\\mathbf", "\\mathrm", "\\mathit", "\\mathsf", "\\mathfrak", "\\boldsymbol",
        "\\text", "\\ensuremath", "\\displaystyle", "\\textstyle", "\\overline", "\\underline", "\\hat", "\\bar",
        "\\vec", "\\dot", "\\ddot", "\\tilde", "\\widehat", "\\widetilde", "\\alpha", "\\beta", "\\gamma",
        "\\delta", "\\epsilon", "\\varepsilon", "\\zeta", "\\eta", "\\theta", "\\vartheta", "\\iota", "\\kappa",
        "\\lambda", "\\mu", "\\nu", "\\xi", "\\pi", "\\rho", "\\sigma", "\\tau", "\\upsilon", "\\phi", "\\varphi",
        "\\chi", "\\psi", "\\omega", "\\Gamma", "\\Delta", "\\Theta", "\\Lambda", "\\Xi", "\\Pi", "\\Sigma",
        "\\Upsilon", "\\Phi", "\\Psi", "\\Omega", "\\newtheorem", "\\theoremstyle", "\\DeclareMathOperator",
        "\\graphicspath", "\\pagestyle", "\\thispagestyle", "\\setcounter", "\\addtocounter", "\\renewcommand",
        "\\newcommand", "\\def", "\\let", "\\hypersetup", "\\geometry", "\\setlength", "\\linespread"
    ]

    static let environments: [String] = [
        "document", "abstract", "center", "flushleft", "flushright", "quote", "quotation", "verse",
        "itemize", "enumerate", "description", "equation", "equation*", "align", "align*", "alignat",
        "gather", "gather*", "multline", "multline*", "split", "cases", "array", "matrix", "pmatrix",
        "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "figure", "figure*", "table", "table*",
        "tabular", "tabularx", "longtable", "minipage", "verbatim", "lstlisting", "minted", "theorem",
        "lemma", "corollary", "proposition", "definition", "remark", "example", "proof", "algorithm",
        "algorithmic", "tikzpicture", "axis", "thebibliography", "filecontents"
    ]

    static let packages: [String] = [
        "amsmath", "amssymb", "amsthm", "mathtools", "bm", "mathrsfs", "graphicx", "geometry", "xcolor",
        "hyperref", "cleveref", "booktabs", "array", "multirow", "longtable", "tabularx", "caption",
        "subcaption", "enumitem", "setspace", "fancyhdr", "titlesec", "tocloft", "natbib", "biblatex",
        "url", "siunitx", "pgfplots", "tikz", "listings", "minted", "ctex", "fontspec", "xeCJK",
        "unicode-math", "algorithm", "algorithmic", "algorithm2e", "float", "wrapfig", "epstopdf",
        "microtype", "parskip", "indentfirst", "footmisc", "ragged2e", "threeparttable", "makecell"
    ]
}
