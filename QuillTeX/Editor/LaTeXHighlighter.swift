import Foundation
import AppKit

/// A LaTeX-aware scanner that turns source text into typed spans for the editor.
///
/// This is a real scanner rather than a pile of regular expressions: it reads verbatim
/// environments, math mode, escapes, control symbols and brace nesting the way LaTeX
/// itself does, so a `%` inside `\verb|%|`, an escaped `\{`, a `$` inside a comment and
/// a `}` with nothing open are each classified for what they are.
enum LaTeXHighlighter {
    enum Token: Equatable {
        case command          // \section
        case controlSymbol    // \\ \% \, \#1
        case environment      // the name inside \begin{…} / \end{…}
        case key              // the argument of \label, \ref, \cite, \input …
        case brace            // { }
        case unmatchedBrace   // a } that closes nothing
        case mathDelimiter    // $ \( \) \[ \]
        case mathBody         // the text between math delimiters
        case comment          // % to the end of the line
        case verbatim         // verbatim, lstlisting, minted, comment, \verb|…|
    }

    struct Span: Equatable {
        var range: NSRange
        var token: Token
        var inMath: Bool = false
    }

    // MARK: - Vocabulary

    private static let environmentCommands: Set<String> = ["begin", "end"]
    private static let keyCommands: Set<String> = [
        "label", "ref", "eqref", "pageref", "autoref", "cref", "Cref", "cite", "citep", "citet", "citealp",
        "parencite", "textcite", "autocite", "footcite", "nocite", "input", "include", "includegraphics",
        "bibliography", "addbibresource", "documentclass", "usepackage", "url", "href"
    ]
    /// Environments whose body is mathematics.
    private static let mathEnvironments: Set<String> = [
        "math", "displaymath", "equation", "equation*", "align", "align*", "alignat", "alignat*",
        "gather", "gather*", "multline", "multline*", "flalign", "flalign*", "eqnarray", "eqnarray*", "split"
    ]
    private static let verbatimEnvironments: Set<String> = [
        "verbatim", "Verbatim", "lstlisting", "minted", "comment", "filecontents"
    ]

    // MARK: - Characters

    private static let backslash: UInt16 = 0x5C
    private static let percent: UInt16 = 0x25
    private static let dollar: UInt16 = 0x24
    private static let openBrace: UInt16 = 0x7B
    private static let closeBrace: UInt16 = 0x7D
    private static let openBracket: UInt16 = 0x5B
    private static let closeBracket: UInt16 = 0x5D
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
    private static let newline: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D
    private static let hash: UInt16 = 0x23
    private static let star: UInt16 = 0x2A
    private static let pipe: UInt16 = 0x7C

    private enum Math { case none, single, double, parenthesis }

    // MARK: - Scanning

    static func spans(in text: String) -> [Span] {
        let units = Array(text.utf16)
        let count = units.count
        var spans: [Span] = []
        var index = 0
        var math = Math.none
        var depth = 0
        var verbatim: (name: String, start: Int)?
        var mathEnvironment: String?
        var mathRun: Int?

        func isLetter(_ value: UInt16) -> Bool {
            (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A) || value == 0x40
        }
        func isSpace(_ value: UInt16) -> Bool {
            value == space || value == tab || value == newline || value == carriageReturn
        }
        func emit(_ start: Int, _ length: Int, _ token: Token) {
            guard length > 0, start >= 0, start + length <= count else { return }
            spans.append(Span(range: NSRange(location: start, length: length), token: token, inMath: math != .none))
        }
        /// End of the brace group that starts at `start` (which must be `{`).
        func groupEnd(_ start: Int) -> Int {
            var cursor = start, level = 0
            while cursor < count {
                if units[cursor] == backslash { cursor += 2; continue }
                if units[cursor] == openBrace { level += 1 }
                if units[cursor] == closeBrace {
                    level -= 1
                    if level == 0 { return cursor + 1 }
                }
                cursor += 1
            }
            return count
        }
        func substring(_ range: NSRange) -> String {
            guard range.location >= 0, NSMaxRange(range) <= count else { return "" }
            return String(decoding: units[range.location..<NSMaxRange(range)], as: UTF16.self)
        }
        func flushMathRun(upTo end: Int) {
            if let start = mathRun, end > start {
                spans.append(Span(range: NSRange(location: start, length: end - start), token: .mathBody, inMath: true))
            }
            mathRun = nil
        }

        while index < count {
            // Inside a verbatim environment nothing else counts.
            if let active = verbatim {
                let marker = "\\end{\(active.name)}"
                if let found = find(marker, in: units, from: index) {
                    emit(active.start, found - active.start, .verbatim)
                    verbatim = nil
                    index = found
                    continue
                }
                emit(active.start, count - active.start, .verbatim)
                break
            }

            let unit = units[index]

            if unit == percent {
                flushMathRun(upTo: index)
                var end = index
                while end < count, units[end] != newline, units[end] != carriageReturn { end += 1 }
                emit(index, end - index, .comment)
                index = end
                continue
            }

            if unit == dollar {
                flushMathRun(upTo: index)
                let doubled = index + 1 < count && units[index + 1] == dollar
                emit(index, doubled ? 2 : 1, .mathDelimiter)
                index += doubled ? 2 : 1
                if doubled { math = math == .double ? .none : .double }
                else { math = math == .single ? .none : .single }
                continue
            }

            if unit == openBrace || unit == closeBrace {
                flushMathRun(upTo: index)
                if unit == openBrace {
                    depth += 1
                    emit(index, 1, .brace)
                } else {
                    depth -= 1
                    emit(index, 1, depth < 0 ? .unmatchedBrace : .brace)
                    if depth < 0 { depth = 0 }
                }
                index += 1
                continue
            }

            if unit == hash, index + 1 < count, units[index + 1] >= 0x30, units[index + 1] <= 0x39 {
                flushMathRun(upTo: index)
                emit(index, 2, .controlSymbol)
                index += 2
                continue
            }

            guard unit == backslash else {
                if math != .none, mathRun == nil { mathRun = index }
                index += 1
                continue
            }

            flushMathRun(upTo: index)
            guard index + 1 < count else { emit(index, 1, .controlSymbol); index += 1; continue }
            let next = units[index + 1]

            guard isLetter(next) else {
                let symbol = substring(NSRange(location: index + 1, length: 1))
                if symbol == "(" || symbol == ")" {
                    emit(index, 2, .mathDelimiter); math = symbol == "(" ? .parenthesis : .none
                } else if symbol == "[" || symbol == "]" {
                    emit(index, 2, .mathDelimiter); math = symbol == "[" ? .double : .none
                } else {
                    emit(index, 2, .controlSymbol)
                }
                index += 2
                continue
            }

            var end = index + 1
            while end < count, isLetter(units[end]) { end += 1 }
            let name = substring(NSRange(location: index + 1, length: end - index - 1))
            var commandEnd = end
            if commandEnd < count, units[commandEnd] == star { commandEnd += 1 }
            emit(index, commandEnd - index, .command)

            // \verb|…| switches to a literal run until the next delimiter character.
            if name == "verb", commandEnd < count {
                let delimiter = units[commandEnd]
                var cursor = commandEnd + 1
                while cursor < count, units[cursor] != delimiter, units[cursor] != newline { cursor += 1 }
                let stop = min(count, cursor < count ? cursor + 1 : count)
                emit(commandEnd, stop - commandEnd, .verbatim)
                index = stop
                continue
            }

            // \begin{…}, \ref{…}, \cite{…}: the braced argument is a name, not code.
            if environmentCommands.contains(name) || keyCommands.contains(name) {
                var cursor = commandEnd
                while cursor < count, isSpace(units[cursor]) { cursor += 1 }
                if cursor < count, units[cursor] == openBracket {
                    var level = 0
                    while cursor < count {
                        if units[cursor] == openBracket { level += 1 }
                        if units[cursor] == closeBracket { level -= 1; if level == 0 { cursor += 1; break } }
                        cursor += 1
                    }
                    while cursor < count, isSpace(units[cursor]) { cursor += 1 }
                }
                if cursor < count, units[cursor] == openBrace {
                    let stop = groupEnd(cursor)
                    let inner = NSRange(location: cursor + 1, length: max(0, stop - cursor - 2))
                    emit(cursor, 1, .brace)
                    let token: Token = environmentCommands.contains(name) ? .environment : .key
                    emit(inner.location, inner.length, token)
                    if stop - 1 > cursor { emit(stop - 1, 1, .brace) }
                    if name == "begin" {
                        let environment = substring(inner)
                        if verbatimEnvironments.contains(environment) { verbatim = (environment, stop) }
                        if mathEnvironments.contains(environment) { mathEnvironment = environment; math = .parenthesis }
                    } else if name == "end" {
                        let environment = substring(inner)
                        if environment == mathEnvironment { mathEnvironment = nil; math = .none }
                    }
                    index = stop
                    continue
                }
            }
            index = commandEnd
        }

        flushMathRun(upTo: count)
        return spans
    }

    private static func find(_ needle: String, in units: [UInt16], from start: Int) -> Int? {
        let pattern = Array(needle.utf16)
        guard !pattern.isEmpty, units.count >= pattern.count else { return nil }
        var index = max(0, start)
        while index <= units.count - pattern.count {
            if units[index] == pattern[0] {
                var matches = true
                for offset in 1..<pattern.count where units[index + offset] != pattern[offset] { matches = false; break }
                if matches { return index }
            }
            index += 1
        }
        return nil
    }
}

/// The editor's colours, in the spirit of TeXifier's default scheme: commands blue,
/// names teal, reference keys ochre, math a muted maroon, comments green.
enum LaTeXPalette {
    static func color(for span: LaTeXHighlighter.Span) -> NSColor {
        switch span.token {
        case .command: NSColor(srgbRed: 0.09, green: 0.30, blue: 0.68, alpha: 1)
        case .controlSymbol: NSColor(srgbRed: 0.47, green: 0.24, blue: 0.61, alpha: 1)
        case .environment: NSColor(srgbRed: 0.05, green: 0.46, blue: 0.41, alpha: 1)
        case .key: NSColor(srgbRed: 0.55, green: 0.35, blue: 0.05, alpha: 1)
        case .brace: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.24, alpha: 1)
        case .unmatchedBrace: NSColor(srgbRed: 0.78, green: 0.15, blue: 0.15, alpha: 1)
        case .mathDelimiter: NSColor(srgbRed: 0.69, green: 0.21, blue: 0.17, alpha: 1)
        case .mathBody: NSColor(srgbRed: 0.44, green: 0.20, blue: 0.30, alpha: 1)
        case .comment: NSColor(srgbRed: 0.22, green: 0.45, blue: 0.22, alpha: 1)
        case .verbatim: NSColor(srgbRed: 0.34, green: 0.34, blue: 0.37, alpha: 1)
        }
    }
}
