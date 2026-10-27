import Foundation

/// Prefix-based inline completions for the editor.
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
        var openEnvironments: [String] = []
        var inMath = false
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
        var result: Suggestion
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
            let lineStart = ns.lineRange(for: NSRange(location: limit, length: 0)).location
            while brace > lineStart {
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
        let spans = LaTeXHighlighter.spans(in: prefix)
        let excluded = spans.filter { $0.token == .comment || $0.token == .verbatim }
        let checkedStart = result.prefix.isEmpty ? max(0, result.range.location - 1) : result.range.location
        let checkedRange = NSRange(location: checkedStart, length: max(1, limit - checkedStart))
        guard !excluded.contains(where: { NSIntersectionRange($0.range, checkedRange).length > 0 }) else { return nil }
        result.inMath = spans.contains { $0.inMath && NSIntersectionRange($0.range, checkedRange).length > 0 }
        if result.context == .endEnvironment {
            result.openEnvironments = openEnvironments(in: ns.substring(to: result.range.location))
        }
        return result
    }

    // MARK: - Candidates

    static func candidates(for suggestion: Suggestion, labels: [String], citations: [String],
                           projectCommands: [String] = [], projectEnvironments: [String] = []) -> [String] {
        let pool: [String]
        switch suggestion.context {
        case .command: pool = commands + projectCommands
        case .environment: pool = environments + projectEnvironments
        case .endEnvironment: pool = suggestion.openEnvironments + environments + projectEnvironments
        case .package: pool = packages
        case .label: pool = labels
        case .citation: pool = citations
        }
        // Commands carry their backslash, the typed text does not: compare without it.
        func key(_ value: String) -> String {
            (value.hasPrefix("\\") ? String(value.dropFirst()) : value).lowercased()
        }
        let needle = key(suggestion.prefix)
        let custom: Set<String>
        switch suggestion.context {
        case .command: custom = Set(projectCommands)
        case .environment, .endEnvironment: custom = Set(projectEnvironments)
        default: custom = []
        }
        return Array(Set(pool))
            .filter { needle.isEmpty || key($0).hasPrefix(needle) }
            .sorted { first, second in
                let a = key(first), b = key(second)
                if suggestion.context == .endEnvironment {
                    let nearest = Array(suggestion.openEnvironments.reversed())
                    let firstRank = nearest.firstIndex(of: first) ?? Int.max
                    let secondRank = nearest.firstIndex(of: second) ?? Int.max
                    if firstRank != secondRank { return firstRank < secondRank }
                }
                if custom.contains(first) != custom.contains(second) { return custom.contains(first) }
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
                if !hasClosingEnvironment(candidate, in: tail) {
                    let newline = source.contains("\r\n") ? "\r\n" : "\n"
                    let indent = indentation(in: source, at: range.location)
                    text += newline + indent + "  "
                    placeholders = [NSRange(location: text.utf16.count, length: 0)]
                    text += newline + indent + closing
                }
            }
        } else if suggestion.context == .command {
            var cursor = next
            // Reuse existing optional/required groups, including their contents.
            // Their ranges belong to the same snippet as newly inserted arguments.
            while let group = argumentGroup(in: ns, at: cursor, opening: 0x5B, closing: 0x5D) {
                let suffix = ns.substring(with: NSRange(location: cursor, length: NSMaxRange(group.range) - cursor))
                if group.contentLength == 0 { placeholders.append(NSRange(location: text.utf16.count + group.range.location - cursor + 1, length: 0)) }
                text += suffix + String(repeating: "]", count: group.missingClosers)
                cursor = NSMaxRange(group.range)
            }
            var argument = 0
            let expectedArguments = commandArguments[candidate]
            while expectedArguments.map({ argument < $0 }) ?? true {
                if let group = argumentGroup(in: ns, at: cursor, opening: openBrace, closing: 0x7D) {
                    placeholders.append(NSRange(location: text.utf16.count + group.range.location - cursor + 1, length: group.contentLength))
                    text += ns.substring(with: NSRange(location: cursor, length: NSMaxRange(group.range) - cursor))
                    text += String(repeating: "}", count: group.missingClosers)
                    cursor = NSMaxRange(group.range)
                } else if expectedArguments != nil {
                    text += "{"
                    placeholders.append(NSRange(location: text.utf16.count, length: 0))
                    text += "}"
                } else { break }
                argument += 1
            }
            range.length = cursor - range.location
            if candidate == "\\end", let name = openEnvironments(in: ns.substring(to: range.location)).last,
               let argument = placeholders.first, argument.length == 0 {
                let expanded = NSMutableString(string: text)
                expanded.replaceCharacters(in: argument, with: name)
                text = expanded as String
                placeholders = []
            }
        } else if suggestion.context == .label || suggestion.context == .citation || suggestion.context == .package {
            if hasBrace { range.length += 1 }
            // A comma continues this argument; a closing brace completes it.
            if hasBrace || next == ns.length || ns.character(at: next) != 0x2C { text += "}" }
        }
        return Insertion(range: range, text: text, placeholders: placeholders, finalOffset: text.utf16.count)
    }

    private struct ArgumentGroup {
        var range: NSRange
        var missingClosers = 0
        var contentLength: Int { max(0, range.length - (missingClosers == 0 ? 2 : 1)) }
    }

    private static func argumentGroup(in ns: NSString, at offset: Int, opening: UInt16, closing: UInt16) -> ArgumentGroup? {
        var start = offset
        while start < ns.length, ns.character(at: start) == 0x20 || ns.character(at: start) == 0x09 { start += 1 }
        guard start < ns.length, ns.character(at: start) == opening else { return nil }
        var depth = 0
        var lineEnd: (offset: Int, depth: Int)?
        for cursor in start..<ns.length where !escaped(cursor, in: ns) {
            let unit = ns.character(at: cursor)
            if lineEnd == nil, unit == 0x0A || unit == 0x0D { lineEnd = (cursor, depth) }
            if unit == opening { depth += 1 }
            if unit == closing {
                depth -= 1
                if depth == 0 { return ArgumentGroup(range: NSRange(location: start, length: cursor - start + 1)) }
            }
        }
        // Repair only the current line when no closing delimiter exists anywhere.
        let end = lineEnd ?? (ns.length, depth)
        return ArgumentGroup(range: NSRange(location: start, length: end.offset - start), missingClosers: end.depth)
    }

    private static let environmentPattern = try! NSRegularExpression(pattern: #"\\(begin|end)\s*\{([^{}\r\n]+)\}"#)
    private static func environmentTokens(in source: String) -> [(opening: Bool, name: String)] {
        let ns = source as NSString
        let excluded = LaTeXHighlighter.spans(in: source).filter { $0.token == .comment || $0.token == .verbatim }
        return environmentPattern.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard !escaped(match.range.location, in: ns),
                  !excluded.contains(where: { NSLocationInRange(match.range.location, $0.range) }) else { return nil }
            return (ns.substring(with: match.range(at: 1)) == "begin", ns.substring(with: match.range(at: 2)))
        }
    }

    static func openEnvironments(in source: String) -> [String] {
        var stack: [String] = []
        for token in environmentTokens(in: source) {
            if token.opening { stack.append(token.name) }
            else if let index = stack.lastIndex(of: token.name) { stack.removeSubrange(index...) }
        }
        return stack
    }

    private static func hasClosingEnvironment(_ name: String, in tail: String) -> Bool {
        var depth = 0
        for token in environmentTokens(in: tail) where token.name == name {
            if token.opening { depth += 1 }
            else if depth == 0 { return true }
            else { depth -= 1 }
        }
        return false
    }

    private static func indentation(in source: String, at offset: Int) -> String {
        let ns = source as NSString
        let line = ns.lineRange(for: NSRange(location: offset, length: 0))
        return String(ns.substring(with: line).prefix { $0 == " " || $0 == "\t" })
    }

    /// Single-key edits only. Paste, marked text and completion expansions bypass
    /// these rules, so authored source is never rewritten on insertion.
    static func typingInsertion(_ typed: String, range: NSRange, in source: String, expandPairs: Bool = true) -> Insertion? {
        guard typed.utf16.count == 1, "{}()[]\\".contains(typed), range.location >= 0,
              NSMaxRange(range) <= source.utf16.count else { return nil }
        if !expandPairs, "{([".contains(typed) { return nil }
        let ns = source as NSString
        if !expandPairs {
            guard range.length == 0, range.location < ns.length else { return nil }
            let tail = ns.substring(from: range.location)
            guard tail.hasPrefix(typed) || tail.hasPrefix("\\right" + typed) ||
                    tail.hasPrefix("\\right\\" + typed) else { return nil }
        }
        let prefix = ns.substring(to: range.location)
        let excluded = LaTeXHighlighter.spans(in: prefix).filter { $0.token == .comment || $0.token == .verbatim }
        guard !excluded.contains(where: { NSMaxRange($0.range) == range.location }) else { return nil }
        let unit = typed.utf16.first!
        let isEscaped = escaped(range.location, in: ns)
        if typed == "\\" {
            // Reuse the slash in an automatically paired \), \] or \}.
            guard !isEscaped, range.length == 0, range.location + 1 < ns.length,
                  ns.character(at: range.location) == backslash else { return nil }
            let close = ns.character(at: range.location + 1)
            guard let open = [UInt16(0x29): UInt16(0x28), 0x5D: 0x5B, 0x7D: 0x7B][close] else { return nil }
            var depth = 0
            for index in 0..<range.location where escaped(index, in: ns) &&
                !excluded.contains(where: { NSLocationInRange(index, $0.range) }) {
                if ns.character(at: index) == open { depth += 1 }
                if ns.character(at: index) == close { depth -= 1 }
            }
            return depth > 0 ? Insertion(range: range, text: "", finalOffset: 1) : nil
        }
        if expandPairs, typed == "}", !isEscaped, range.length == 0,
           let match = prefix.range(of: #"\\begin\{([^{}\s]+)$"#, options: .regularExpression),
           !escaped(NSRange(match, in: prefix).location, in: ns) {
            let begin = String(prefix[match])
            let name = String(begin.dropFirst(7))
            let consumed = range.location < ns.length && ns.character(at: range.location) == 0x7D ? 1 : 0
            if !hasClosingEnvironment(name, in: ns.substring(from: range.location + consumed)) {
                let newline = source.contains("\r\n") ? "\r\n" : "\n"
                let indent = indentation(in: source, at: range.location)
                let body = "}" + newline + indent + "  "
                return Insertion(range: NSRange(location: range.location, length: consumed),
                    text: body + newline + indent + "\\end{\(name)}", finalOffset: body.utf16.count)
            }
        }
        let pairs: [UInt16: UInt16] = [0x7B: 0x7D, 0x28: 0x29, 0x5B: 0x5D]
        if expandPairs, let closing = pairs[unit] {
            let selected = ns.substring(with: range)
            let left = prefix.range(of: #"\\left\s*\\?$"#, options: .regularExpression)
            let needsRight = left.map { !escaped(NSRange($0, in: prefix).location, in: ns) } ?? false
            let suffix = (needsRight ? "\\right" : "") + (isEscaped ? "\\" : "") + String(UnicodeScalar(closing)!)
            return Insertion(range: range, text: typed + selected + suffix,
                             placeholders: range.length > 0 ? [NSRange(location: 1, length: range.length)] : [],
                             finalOffset: 1 + range.length)
        }
        guard range.length == 0, range.location < ns.length,
              let opening = pairs.first(where: { $0.value == unit })?.key else { return nil }
        let tail = ns.substring(from: range.location)
        let right = "\\right" + typed
        let escapedRight = "\\right\\" + typed
        let rightLength = tail.hasPrefix(right) ? right.utf16.count : (tail.hasPrefix(escapedRight) ? escapedRight.utf16.count : 0)
        guard ns.character(at: range.location) == unit || rightLength > 0 else { return nil }
        let openingEscaped = rightLength > 0 ? tail.hasPrefix(escapedRight) : isEscaped
        var depth = 0
        for index in 0..<range.location where escaped(index, in: ns) == openingEscaped &&
            !excluded.contains(where: { NSLocationInRange(index, $0.range) }) {
            let value = ns.character(at: index)
            if value == opening { depth += 1 }
            if value == unit { depth -= 1 }
        }
        // Skip a closer that already belongs to an opening delimiter.
        return depth > 0 ? Insertion(range: range, text: "", finalOffset: max(1, rightLength)) : nil
    }

    /// Propose the last typed delimiter without modifying the buffer.
    static func delimiterHint(in source: String, at offset: Int) -> Insertion? {
        let ns = source as NSString
        guard offset > 0, offset <= ns.length else { return nil }
        let position = offset - 1
        let typed = ns.substring(with: NSRange(location: position, length: 1))
        guard "{([}".contains(typed),
              let edit = typingInsertion(typed, range: NSRange(location: position, length: 0), in: source),
              !edit.text.isEmpty else { return nil }
        // A completed begin statement is replaced as a whole closing brace.
        if typed == "}" { return edit }
        let suffix = String(edit.text.dropFirst())
        guard !ns.substring(from: offset).hasPrefix(suffix) else { return nil }
        return Insertion(range: NSRange(location: position, length: 1), text: edit.text,
                         finalOffset: edit.finalOffset)
    }

    static func delimiterPreview(for edit: Insertion, in source: String, at offset: Int) -> InlinePreview {
        let ns = source as NSString
        let line = ns.lineRange(for: NSRange(location: offset, length: 0))
        let tail = ns.substring(with: NSRange(location: offset, length: NSMaxRange(line) - offset))
        let newlineLength = tail.hasSuffix("\r\n") ? 2 : (tail.hasSuffix("\n") || tail.hasSuffix("\r") ? 1 : 0)
        let end = NSMaxRange(line) - newlineLength
        let suffix = String(edit.text.dropFirst()).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ↵ ")
        return InlinePreview(text: suffix, coveredBrace: nil,
                             coveredTail: offset < end ? NSRange(location: offset, length: end - offset) : nil,
                             trailingText: offset < end ? NSRange(location: offset, length: end - offset) : nil)
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
        var inMath = false
    }

    struct InlinePreview: Equatable, Sendable {
        /// The visible suffix, including parameter delimiters from the insertion.
        var text: String
        /// A closing brace already in the source, temporarily covered while its
        /// preview is painted after the proposed name. Source offsets stay intact.
        var coveredBrace: NSRange?
        /// A math suffix is repainted after the hint, without editing the buffer.
        var coveredTail: NSRange? = nil
        var trailingText: NSRange? = nil
    }

    static func inlinePreview(for hint: Inline, in source: String, at offset: Int) -> InlinePreview? {
        let ns = source as NSString
        guard NSMaxRange(hint.range) == offset, offset <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: offset, length: 0))
        let tail = ns.substring(with: NSRange(location: offset, length: NSMaxRange(line) - offset))
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        let argument = hint.context != .command
        let hasBrace = argument && tail.hasPrefix("}") && trimmed == "}"
        // Other source text must remain readable in its native position.
        let closingTail = tail.range(of: #"^(?:[\s}\])$]|\\[)\]])+$"#, options: .regularExpression) != nil
        let moveTail = !trimmed.isEmpty && !hasBrace && (hint.inMath || closingTail)
        guard trimmed.isEmpty || hasBrace || moveTail else { return nil }
        let suggestion = Suggestion(context: hint.context, range: hint.range,
                                    prefix: ns.substring(with: hint.range))
        let insertion = insertion(for: hint.full, suggestion: suggestion, in: source)
        let firstLine = insertion.text.prefix { $0 != "\n" && $0 != "\r" }
        let preview = String(firstLine.dropFirst(suggestion.prefix.count))
        guard !preview.isEmpty else { return nil }
        if moveTail {
            let end = NSMaxRange(line) - (tail.hasSuffix("\r\n") ? 2 : (tail.hasSuffix("\n") || tail.hasSuffix("\r") ? 1 : 0))
            guard NSMaxRange(insertion.range) <= end else { return nil }
            let remaining = max(offset, NSMaxRange(insertion.range))
            return InlinePreview(text: preview, coveredBrace: nil,
                coveredTail: NSRange(location: offset, length: end - offset),
                trailingText: NSRange(location: remaining, length: end - remaining))
        }
        return InlinePreview(text: preview, coveredBrace: hasBrace ? NSRange(location: offset, length: 1) : nil)
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
        let hasArguments = suggestion.context == .command && (commandArguments[best] ?? 0) > 0
        guard candidate.lowercased().hasPrefix(typed.lowercased()),
              candidate.count > typed.count || hasArguments else { return nil }
        return Inline(full: best,
                      remainder: String(candidate.dropFirst(typed.count)),
                      range: suggestion.range,
                      context: suggestion.context, inMath: suggestion.inMath)
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
        "\\begin": 1, "\\end": 1, "\\documentclass": 1, "\\usepackage": 1,
        "\\section": 1, "\\section*": 1, "\\subsection": 1, "\\subsection*": 1,
        "\\subsubsection": 1, "\\paragraph": 1, "\\chapter": 1, "\\part": 1,
        "\\title": 1, "\\author": 1, "\\date": 1, "\\caption": 1, "\\footnote": 1,
        "\\label": 1, "\\ref": 1, "\\eqref": 1, "\\pageref": 1, "\\autoref": 1,
        "\\cref": 1, "\\Cref": 1, "\\cite": 1, "\\citep": 1, "\\citet": 1,
        "\\parencite": 1, "\\textcite": 1, "\\input": 1, "\\include": 1,
        "\\includegraphics": 1, "\\emph": 1, "\\textbf": 1, "\\textit": 1, "\\texttt": 1,
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
