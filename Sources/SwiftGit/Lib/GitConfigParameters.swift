import Foundation

/// `GIT_CONFIG_PARAMETERS`, the variable `git -c <name>[=<value>]` hands its
/// entries on in, written and read as git's `config.c` does
/// (`git_config_push_parameter`, `parse_config_env_list`) with `quote.c`'s
/// single quoting (`sq_quote_buf`, `sq_dequote_step`).
package enum GitConfigParameters {

    /// The variable `existing` becomes once `text` (one `-c` operand) is
    /// added: `'<name>'='<value>'`, split at the first `=`, or `'<name>'=`
    /// for an operand without one (a valueless, boolean-true entry).
    package static func push(_ text: String, onto existing: String?) -> String {
        var out = ""
        if let existing, !existing.isEmpty {
            out = existing + " "
        }
        if let equals = text.firstIndex(of: "=") {
            out += quote(String(text[..<equals])) + "=" + quote(String(text[text.index(after: equals)...]))
        } else {
            out += quote(text) + "="
        }
        return out
    }

    /// `sq_quote_buf`: in single quotes, with `'` and `!` stepped out of them
    /// (`'\''`, `'\!'`).
    package static func quote(_ text: String) -> String {
        var out = "'"
        for character in text {
            if character == "'" || character == "!" {
                out += "'\\\(character)'"
            } else {
                out.append(character)
            }
        }
        return out + "'"
    }

    /// The entries of `text`, in order: each key as written and its value,
    /// `nil` for a valueless one. `each` sees one before the next is read,
    /// so what it throws comes first, as git stops at the first bad entry.
    /// What git can't read throws git's `error:` reason.
    package static func entries(
        _ text: String, _ each: (_ key: String, _ value: String?) throws -> Void
    ) throws {
        let bytes = Array(text.utf8)
        var position = 0
        let bogus = CommandLineConfigError(reason: "bogus format in GIT_CONFIG_PARAMETERS")
        while position < bytes.count {
            guard let key = dequoteStep(bytes, at: &position) else { throw bogus }
            if position >= bytes.count || isSpace(bytes[position]) {
                // Old style, 'key=value' or 'key'.
                try legacyParameter(key, each)
            } else if bytes[position] == UInt8(ascii: "=") {
                position += 1
                let value: String?
                if position < bytes.count, bytes[position] == UInt8(ascii: "'") {
                    guard let quoted = dequoteStep(bytes, at: &position),
                          position >= bytes.count || isSpace(bytes[position]) else { throw bogus }
                    value = quoted
                } else if position >= bytes.count || isSpace(bytes[position]) {
                    // 'key'= — an implicit boolean.
                    value = nil
                } else {
                    throw bogus
                }
                try each(key, value)
            } else {
                throw bogus
            }
            while position < bytes.count, isSpace(bytes[position]) { position += 1 }
        }
    }

    /// `git_config_parse_parameter`: split at the first `=`, a key required.
    private static func legacyParameter(
        _ text: String, _ each: (_ key: String, _ value: String?) throws -> Void
    ) throws {
        let key: String, value: String?
        if let equals = text.firstIndex(of: "=") {
            key = String(text[..<equals])
            value = String(text[text.index(after: equals)...])
        } else {
            key = text
            value = nil
        }
        guard !key.isEmpty else {
            throw CommandLineConfigError(reason: "bogus config parameter: \(text)")
        }
        try each(key, value)
    }

    /// `sq_dequote_step`: one single-quoted word starting at `position`,
    /// which is left on the byte after it. Between quoted parts only a
    /// backslashed `'` or `!` is taken.
    private static func dequoteStep(_ bytes: [UInt8], at position: inout Int) -> String? {
        guard position < bytes.count, bytes[position] == UInt8(ascii: "'") else { return nil }
        var word: [UInt8] = []
        var index = position + 1
        while true {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            if byte != UInt8(ascii: "'") {
                word.append(byte)
                continue
            }
            // Out of the quotes.
            if index + 2 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
               bytes[index + 1] == UInt8(ascii: "'") || bytes[index + 1] == UInt8(ascii: "!"),
               bytes[index + 2] == UInt8(ascii: "'") {
                word.append(bytes[index + 1])
                index += 3
                continue
            }
            position = index
            return String(decoding: word, as: UTF8.self)
        }
    }

    /// git's `isspace`: space, tab, newline, carriage return.
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
