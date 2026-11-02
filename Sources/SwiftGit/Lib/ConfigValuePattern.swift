import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// The `<value-pattern>` of `git config --get` / `--unset`: a POSIX
/// extended regular expression (git's `regcomp(…, REG_EXTENDED)`), which a
/// leading `!` negates. Compiled by the platform's `regcomp`, as git's is on
/// macOS and Linux; `NSRegularExpression` stands in on Windows.
struct ConfigValuePattern {
    /// `!pattern`: the values the pattern doesn't match.
    let negated: Bool
    /// The pattern without its `!`, as git names it in `invalid pattern: …`.
    let text: String
    private let compiled: Compiled

    /// git's `error: invalid pattern: <text>` (status 6) for what won't compile.
    init(_ pattern: String) throws {
        negated = pattern.hasPrefix("!")
        text = negated ? String(pattern.dropFirst()) : pattern
        guard let compiled = Compiled(text) else {
            throw GitDiagnosticError(lines: ["error: invalid pattern: \(text)"], exitCode: 6)
        }
        self.compiled = compiled
    }

    /// Whether `git config --get` shows `value` for the pattern: a key
    /// without a value reads as an empty one (`collect_config`).
    func admitsForGet(_ value: String?) -> Bool {
        negated != compiled.matches(Array((value ?? "").utf8))
    }

    /// Whether `git config --unset` removes `value`: a key without a value
    /// matches no pattern, so only a negated one takes it (`matches`).
    func admitsForUnset(_ value: [UInt8]?) -> Bool {
        negated != (value.map(compiled.matches) ?? false)
    }

    #if os(Windows)
    private final class Compiled {
        private let regex: NSRegularExpression

        init?(_ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.regex = regex
        }

        func matches(_ bytes: [UInt8]) -> Bool {
            let string = String(decoding: bytes, as: UTF8.self)
            return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
        }
    }
    #else
    /// A `regex_t`, freed with it.
    private final class Compiled {
        private var regex = regex_t()
        private var valid = false

        init?(_ pattern: String) {
            guard pattern.withCString({ regcomp(&regex, $0, REG_EXTENDED) }) == 0 else { return nil }
            valid = true
        }

        deinit {
            if valid { regfree(&regex) }
        }

        func matches(_ bytes: [UInt8]) -> Bool {
            var terminated = bytes
            terminated.append(0)
            return terminated.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { string in
                    regexec(&regex, string, 0, nil, 0) == 0
                }
            }
        }
    }
    #endif
}
