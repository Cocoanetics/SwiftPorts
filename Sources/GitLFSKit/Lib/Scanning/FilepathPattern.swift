import Foundation

/// git-lfs/wildmatch v2's `Contents` matching: matching a parent also
/// matches its contents. Patterns are independent, not .gitignore lines
/// (a leading `!` or `#` is literal).
struct FilepathPattern: Sendable {
    private let tokens: [Token]

    private indirect enum Token: Sendable {
        case component(NSRegularExpression?)
        case doubleStar(Token?)

        func consume(_ path: [String], from index: Int) -> Int? {
            guard index < path.count else { return nil }
            switch self {
            case .component(let regex):
                let part = path[index]
                let range = NSRange(part.startIndex..., in: part)
                return regex?.firstMatch(in: part, range: range) != nil ? index + 1 : nil
            case .doubleStar(let until):
                guard let until else { return path.count }
                // wildmatch consumes the rightmost matching successor first.
                // Later components do not backtrack to an earlier successor.
                for candidate in stride(from: path.count, through: index + 1, by: -1) {
                    if let end = until.consume(path, from: candidate) { return end }
                }
                return until.consume(path, from: index)
            }
        }
    }

    init(_ pattern: String) {
        var parts = Self.slashEscape(pattern).components(separatedBy: "/")
        if parts.count > 1 && parts.last == "" { parts.removeLast() }
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        // wildmatch.SystemCase folds on Windows and Darwin.
        #if os(Windows) || canImport(Darwin)
        options.insert(.caseInsensitive)
        #endif
        var parsed: [Token] = []
        for (index, part) in parts.enumerated().reversed() {
            if part == "**" {
                let until = parsed.isEmpty ? nil : parsed.removeFirst()
                parsed.insert(.doubleStar(until), at: 0)
            } else if !part.isEmpty || index == parts.count - 1 {
                let source = "\\A" + Self.component(part) + "\\z"
                parsed.insert(.component(try? NSRegularExpression(pattern: source, options: options)), at: 0)
            }
        }
        // A slash-free pattern can match any component. `Contents` then
        // accepts the remainder, including descendants of a matching parent.
        tokens = parts.count == 1 ? [.doubleStar(parsed.first)] : parsed
    }

    func matches(_ path: String) -> Bool {
        let parts = path.components(separatedBy: "/")
        var index = 0
        for token in tokens {
            guard let end = token.consume(parts, from: index) else { return false }
            index = end
        }
        return true
    }

    /// wildmatch treats a backslash as a path separator unless it escapes
    /// one of `\[]*?#`, on every platform.
    private static func slashEscape(_ pattern: String) -> String {
        let chars = Array(pattern)
        var result = "", index = 0
        while index < chars.count {
            if chars[index] == "\\" {
                if index + 1 < chars.count && "\\[]*?#".contains(chars[index + 1]) {
                    result.append("\\")
                    index += 1
                } else {
                    result.append("/")
                    index += 1
                    continue
                }
            }
            result.append(chars[index])
            index += 1
        }
        return result
    }

    private static func component(_ pattern: String) -> String {
        let chars = Array(pattern)
        var result = "", index = 0
        while index < chars.count {
            switch chars[index] {
            case "*": result += "[^/]*"
            case "?": result += "[^/]"
            case "\\" where index + 1 < chars.count:
                index += 1
                result += NSRegularExpression.escapedPattern(for: String(chars[index]))
            case "[":
                let start = index
                index += 1
                var bracket = "["
                if index < chars.count && (chars[index] == "!" || chars[index] == "^") {
                    bracket += "^"
                    index += 1
                }
                while index < chars.count && chars[index] != "]" {
                    // A POSIX class has an inner closing bracket.
                    if chars[index] == "\\", index + 1 < chars.count {
                        bracket.append("\\")
                        index += 1
                        bracket.append(chars[index])
                        index += 1
                    } else if chars[index] == "[", index + 1 < chars.count, chars[index + 1] == ":" {
                        bracket += "[:"
                        index += 2
                        while index < chars.count && chars[index] != "]" {
                            bracket.append(chars[index])
                            index += 1
                        }
                        if index < chars.count { bracket += "]"; index += 1 }
                    } else {
                        bracket.append(chars[index])
                        index += 1
                    }
                }
                if index < chars.count {
                    result += "(?!/)" + bracket + "]"
                } else {
                    result += NSRegularExpression.escapedPattern(for: String(chars[start...]))
                }
            default:
                result += NSRegularExpression.escapedPattern(for: String(chars[index]))
            }
            index += 1
        }
        return result
    }
}
