/// Glob matching shared by `ssh_config`'s `Host` directive and `known_hosts`' plain (non-hashed)
/// host field, both specified by OpenSSH as a list of patterns using `*`/`?` wildcards with an
/// optional leading `!` negation (`ssh_config(5)` PATTERNS; `match_pattern`/`match_pattern_list`
/// in `match.c`). Matching is byte-wise case-sensitive, matching `match.c`'s implementation.
enum SSHPatternList {
    /// Mirrors the `Host` keyword's token loop in `readconf.c` (`case oHost:`, lines 1833-1868):
    /// a negated token that matches aborts the whole match immediately; any other matching token
    /// makes the result true, but scanning continues (a later negated match can still veto it).
    static func matches(host: String, tokens: [some StringProtocol]) -> Bool {
        var matched = false
        for token in tokens {
            let negated = token.hasPrefix("!")
            let pattern = negated ? token.dropFirst() : token[...]
            if matchesGlob(host: host, pattern: pattern) {
                if negated {
                    return false
                }
                matched = true
            }
        }
        return matched
    }

    /// `*` matches any sequence (including empty), `?` matches exactly one character. Anchored
    /// to the whole string, like `match_pattern()` in `match.c`.
    static func matchesGlob(host: String, pattern: some StringProtocol) -> Bool {
        let hostChars = Array(host)
        let patternChars = Array(pattern)

        guard !patternChars.isEmpty else {
            return hostChars.isEmpty
        }

        // `table[i][j]` = pattern[0..<i] matches host[0..<j].
        var table = [[Bool]](repeating: [Bool](repeating: false, count: hostChars.count + 1), count: patternChars.count + 1)
        table[0][0] = true
        for i in 1...patternChars.count where patternChars[i - 1] == "*" {
            table[i][0] = table[i - 1][0]
        }

        for i in 1...patternChars.count {
            for j in 0...hostChars.count {
                switch patternChars[i - 1] {
                case "*":
                    table[i][j] = table[i - 1][j] || (j > 0 && table[i][j - 1])
                case "?":
                    table[i][j] = j > 0 && table[i - 1][j - 1]
                default:
                    table[i][j] = j > 0 && hostChars[j - 1] == patternChars[i - 1] && table[i - 1][j - 1]
                }
            }
        }

        return table[patternChars.count][hostChars.count]
    }
}
