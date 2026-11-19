import Foundation

/// A `.lfsconfig` file read as git reads a config file (`git_parse_source`).
/// git-lfs parses `.lfsconfig` with `git config -l -z -f`, which is this
/// grammar. Section and variable names are lowercased; a subsection is kept
/// as written.
enum LFSConfigFile {
    /// `fatal: bad config line N in file .lfsconfig`.
    struct ParseError: Error, CustomStringConvertible, Equatable {
        let line: Int
        var description: String { "fatal: bad config line \(line) in file .lfsconfig" }
    }

    /// The entries, in file order. A key written without `=` has an empty value.
    static func parse(_ data: Data) throws -> [(key: String, value: String)] {
        var parser = Parser(bytes: [UInt8](data))
        parser.run()
        if let line = parser.badLine { throw ParseError(line: line) }
        return parser.entries
    }

    private struct Parser {
        let bytes: [UInt8]
        private var position = 0
        private var eof = false
        private var line = 1
        private(set) var badLine: Int?
        private var name: [UInt8] = []
        private var baseLength = 0
        private(set) var entries: [(key: String, value: String)] = []

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func run() {
            var comment = false
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            var bomMatched = 0
            var checkingBOM = true
            while true {
                let c = next()
                if checkingBOM {
                    if c == bom[bomMatched] {
                        bomMatched += 1
                        if bomMatched == bom.count { checkingBOM = false }
                        continue
                    }
                    if bomMatched != 0 { break }
                    checkingBOM = false
                }
                if c == UInt8(ascii: "\n") {
                    if eof { return }
                    comment = false
                    continue
                }
                if comment { continue }
                if isSpace(c) { continue }
                if c == UInt8(ascii: "#") || c == UInt8(ascii: ";") {
                    comment = true
                    continue
                }
                if c == UInt8(ascii: "[") {
                    name.removeAll()
                    guard baseVar(), !name.isEmpty else { break }
                    name.append(UInt8(ascii: "."))
                    baseLength = name.count
                    continue
                }
                guard isAlpha(c) else { break }
                name.removeSubrange(baseLength...)
                name.append(lowercased(c))
                guard value() else { break }
            }
            badLine = line
        }

        /// `[section]` or `[section "subsection"]`.
        private mutating func baseVar() -> Bool {
            while true {
                let c = next()
                if eof { return false }
                if c == UInt8(ascii: "]") { return true }
                if isSpace(c) { return extendedBaseVar(c) }
                guard isKeyChar(c) || c == UInt8(ascii: ".") else { return false }
                name.append(lowercased(c))
            }
        }

        /// The quoted subsection. A backslash takes the next byte as itself.
        private mutating func extendedBaseVar(_ first: UInt8) -> Bool {
            var c = first
            repeat {
                if c == UInt8(ascii: "\n") {
                    line -= 1
                    return false
                }
                c = next()
            } while isSpace(c)
            guard c == UInt8(ascii: "\"") else { return false }
            name.append(UInt8(ascii: "."))
            while true {
                var c = next()
                if c == UInt8(ascii: "\n") {
                    line -= 1
                    return false
                }
                if c == UInt8(ascii: "\"") { break }
                if c == UInt8(ascii: "\\") {
                    c = next()
                    if c == UInt8(ascii: "\n") {
                        line -= 1
                        return false
                    }
                }
                name.append(c)
            }
            return next() == UInt8(ascii: "]")
        }

        private mutating func value() -> Bool {
            var c: UInt8
            while true {
                c = next()
                if eof { break }
                guard isKeyChar(c) else { break }
                name.append(lowercased(c))
            }
            while c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") { c = next() }
            let text: String
            if c != UInt8(ascii: "\n") {
                guard c == UInt8(ascii: "="), let parsed = parseValue() else { return false }
                text = String(decoding: parsed, as: UTF8.self)
            } else {
                text = ""
            }
            entries.append((String(decoding: name, as: UTF8.self), text))
            return true
        }

        private mutating func parseValue() -> [UInt8]? {
            var quote = false
            var comment = false
            var trim = 0
            var value: [UInt8] = []
            while true {
                var c = next()
                if c == UInt8(ascii: "\n") {
                    if quote {
                        line -= 1
                        return nil
                    }
                    if trim != 0 { value.removeSubrange(trim...) }
                    return value
                }
                if comment { continue }
                if isSpace(c) && !quote {
                    if trim == 0 { trim = value.count }
                    if !value.isEmpty { value.append(c) }
                    continue
                }
                if !quote && (c == UInt8(ascii: ";") || c == UInt8(ascii: "#")) {
                    comment = true
                    continue
                }
                trim = 0
                if c == UInt8(ascii: "\\") {
                    c = next()
                    switch c {
                    case UInt8(ascii: "\n"):
                        continue
                    case UInt8(ascii: "t"):
                        c = UInt8(ascii: "\t")
                    case UInt8(ascii: "b"):
                        c = 0x08
                    case UInt8(ascii: "n"):
                        c = UInt8(ascii: "\n")
                    case UInt8(ascii: "\\"), UInt8(ascii: "\""):
                        break
                    default:
                        return nil
                    }
                    value.append(c)
                    continue
                }
                if c == UInt8(ascii: "\"") {
                    quote.toggle()
                    continue
                }
                value.append(c)
            }
        }

        private mutating func next() -> UInt8 {
            var c = fgetc()
            if c == UInt8(ascii: "\r") {
                c = fgetc()
                if c != UInt8(ascii: "\n") {
                    if c != nil { position -= 1 }
                    c = UInt8(ascii: "\r")
                }
            }
            if c == UInt8(ascii: "\n") { line += 1 }
            guard let c else {
                eof = true
                line += 1
                return UInt8(ascii: "\n")
            }
            return c
        }

        private mutating func fgetc() -> UInt8? {
            guard position < bytes.count else { return nil }
            defer { position += 1 }
            return bytes[position]
        }

        private func lowercased(_ byte: UInt8) -> UInt8 {
            byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
        }

        private func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private func isAlpha(_ byte: UInt8) -> Bool {
            let lower = byte | 0x20
            return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
        }

        private func isKeyChar(_ byte: UInt8) -> Bool {
            isAlpha(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "-")
        }
    }
}
