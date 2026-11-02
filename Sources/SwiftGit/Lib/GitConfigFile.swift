import Foundation

/// A config file read as git's `config.c` reads it (`git_parse_source`),
/// for what libgit2's parser doesn't do the same way: the line git names
/// for what it refuses (`bad config line N`; libgit2 takes an unterminated
/// quote, or a key that starts with a digit), and the byte ranges git's
/// `git config --unset` cuts out of the file.
struct GitConfigFile {

    /// What git's parser tells its event callback (`config_event_t`): a
    /// header, a key with its value, white space, or a comment.
    enum EventKind: Equatable {
        case section, entry, whitespace, comment
    }

    /// One parser event: `bytes[begin..<end]` is the header, entry, white
    /// space or comment, as git's `store_aux_event` records it.
    struct Event {
        let kind: EventKind
        let begin: Int
        let end: Int
        /// A header's name as git keeps it, lowercased and ending in `.`
        /// (`remote.origin.`), a quoted subsection as written.
        let section: [UInt8]
        /// Whether the header is the old `[section.subsection]` spelling,
        /// whose subsection git matches without regard to case.
        let dottedSubsection: Bool

        /// Whether this is a header of `key`'s section
        /// (`store_aux_event`'s `is_keys_section`).
        func isSection(of key: [UInt8]) -> Bool {
            guard kind == .section, let dot = key.lastIndex(of: UInt8(ascii: ".")),
                  section.count - 1 == dot
            else { return false }
            return zip(section.prefix(dot), key.prefix(dot)).allSatisfy { ours, theirs in
                dottedSubsection ? GitConfigFile.lowercased(ours) == GitConfigFile.lowercased(theirs) : ours == theirs
            }
        }
    }

    /// A key and its value, as git's `config_fn_t` callback gets them.
    struct Entry {
        /// `section.subsection.name`, section and name lowercased.
        let key: [UInt8]
        /// `nil` for a key written without `=` (`[push] autoSetupRemote`).
        let value: [UInt8]?
        /// The line the entry ends on, counting from 1.
        let line: Int
        /// The index of its event in ``GitConfigFile/events``.
        let event: Int
    }

    let bytes: [UInt8]
    let events: [Event]
    let entries: [Entry]
    /// The line git refuses the file at (`fatal: bad config line N`),
    /// `nil` when git reads all of it.
    let badLine: Int?

    /// Reads `data` as git reads a config file.
    static func parse(_ data: Data) -> GitConfigFile {
        var parser = Parser(bytes: [UInt8](data))
        parser.run()
        return GitConfigFile(bytes: parser.bytes, events: parser.events, entries: parser.entries,
                             badLine: parser.badLine)
    }

    // MARK: git's ctype: ASCII only

    static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
    }

    /// `isspace`: space, tab, LF and CR (not VT or FF).
    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    static func isAlpha(_ byte: UInt8) -> Bool {
        let lower = byte | 0x20
        return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
    }

    /// `iskeychar`: a letter, a digit or `-`.
    static func isKeyChar(_ byte: UInt8) -> Bool {
        isAlpha(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "-")
    }

    // MARK: The parser

    /// git's `config_source` and `git_parse_source`, byte for byte: the
    /// same characters taken, the same lines counted, the same events
    /// raised, so the line it refuses at and the ranges it records are
    /// git's.
    private struct Parser {
        let bytes: [UInt8]
        /// What `do_ftell` would say: the bytes taken so far.
        private var position = 0
        private var eof = false
        private(set) var line = 1
        private(set) var events: [Event] = []
        private(set) var entries: [Entry] = []
        private(set) var badLine: Int?
        /// `cs->var`: the section stem, then the whole key.
        private var name: [UInt8] = []
        private var baseLength = 0
        private var dottedSubsection = false
        /// `parse_event_data`: the event under way, `nil` before the first
        /// and after the last (EOF).
        private var previousKind: EventKind?
        private var previousOffset = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        private mutating func fgetc() -> UInt8? {
            guard position < bytes.count else { return nil }
            defer { position += 1 }
            return bytes[position]
        }

        /// `get_next_char`: CR LF reads as LF, the end of the file as one
        /// more LF, and the line count follows.
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

        /// `do_event`: the event under way ends where this one begins
        /// (`nil` is the end of the file); white space runs together.
        private mutating func event(_ kind: EventKind?) {
            if kind == .whitespace && previousKind == .whitespace { return }
            var offset = position
            if kind != nil { offset -= 1 }
            if let previousKind {
                events.append(Event(kind: previousKind, begin: previousOffset, end: offset,
                                    section: previousKind == .section ? name : [],
                                    dottedSubsection: dottedSubsection))
            }
            previousKind = kind
            previousOffset = offset
        }

        mutating func run() {
            var comment = false
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            var bomMatched = 0
            var checkingBOM = true
            while true {
                let c = next()
                if checkingBOM {
                    // A UTF-8 byte order mark is skipped; part of one is not tolerated.
                    if c == bom[bomMatched] {
                        bomMatched += 1
                        if bomMatched == bom.count { checkingBOM = false }
                        continue
                    }
                    if bomMatched != 0 { break }
                    checkingBOM = false
                }
                if c == UInt8(ascii: "\n") {
                    if eof {
                        event(nil)
                        return
                    }
                    event(.whitespace)
                    comment = false
                    continue
                }
                if comment { continue }
                if GitConfigFile.isSpace(c) {
                    event(.whitespace)
                    continue
                }
                if c == UInt8(ascii: "#") || c == UInt8(ascii: ";") {
                    event(.comment)
                    comment = true
                    continue
                }
                if c == UInt8(ascii: "[") {
                    event(.section)
                    name.removeAll()
                    guard baseVar(), !name.isEmpty else { break }
                    name.append(UInt8(ascii: "."))
                    baseLength = name.count
                    continue
                }
                guard GitConfigFile.isAlpha(c) else { break }
                event(.entry)
                // The key is the section stem and the name that follows.
                name.removeSubrange(baseLength...)
                name.append(GitConfigFile.lowercased(c))
                guard value() else { break }
            }
            badLine = line
        }

        /// `get_base_var`: `[section]`, or `[section "subsection"]`.
        private mutating func baseVar() -> Bool {
            dottedSubsection = true
            while true {
                let c = next()
                if eof { return false }
                if c == UInt8(ascii: "]") { return true }
                if GitConfigFile.isSpace(c) { return extendedBaseVar(c) }
                guard GitConfigFile.isKeyChar(c) || c == UInt8(ascii: ".") else { return false }
                name.append(GitConfigFile.lowercased(c))
            }
        }

        /// `get_extended_base_var`: the quoted subsection, in which a
        /// backslash takes the next character as it is.
        private mutating func extendedBaseVar(_ first: UInt8) -> Bool {
            dottedSubsection = false
            var c = first
            repeat {
                if c == UInt8(ascii: "\n") {
                    line -= 1
                    return false
                }
                c = next()
            } while GitConfigFile.isSpace(c)
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

        /// `get_value`: the rest of the key, then `= value` or nothing.
        private mutating func value() -> Bool {
            var c: UInt8
            while true {
                c = next()
                if eof { break }
                guard GitConfigFile.isKeyChar(c) else { break }
                name.append(GitConfigFile.lowercased(c))
            }
            while c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") { c = next() }
            var value: [UInt8]?
            if c != UInt8(ascii: "\n") {
                guard c == UInt8(ascii: "="), let parsed = parseValue() else { return false }
                value = parsed
            }
            // The LF is taken, but the entry is on the line before it.
            entries.append(Entry(key: name, value: value, line: line - 1, event: events.count))
            return true
        }

        /// `parse_value`: `nil` for what git refuses, an unterminated quote
        /// or an escape it doesn't know.
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
                if GitConfigFile.isSpace(c) && !quote {
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
                    // Some characters escape as themselves.
                    case UInt8(ascii: "\\"), UInt8(ascii: "\""):
                        break
                    // Reject unknown escape sequences.
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
    }
}

// MARK: - What `git config --unset` writes

extension GitConfigFile {

    /// The file with the entries at `indices` (into ``entries``, ascending)
    /// cut out, as `git_config_set_multivar_in_file_gently` writes it for
    /// an unset: each entry's bytes go, with the white space before it on
    /// its line, and a section they leave empty goes with them unless a
    /// comment stands by it (`maybe_remove_section`).
    func removing(entriesAt indices: [Int]) -> [UInt8] {
        guard let first = indices.first else { return bytes }
        let key = entries[first].key
        let seen = indices.map { entries[$0].event }
        var output: [UInt8] = []
        var copyBegin = 0
        var index = 0
        while index < seen.count {
            let event = events[seen[index]]
            var replaceEnd = event.end
            var copyEnd = event.begin
            maybeRemoveSection(seen: seen, key: key, begin: &copyEnd, end: &replaceEnd, index: &index)
            // Swallow preceding white-space on the same line.
            while copyEnd > 0, Self.isSpace(bytes[copyEnd - 1]), bytes[copyEnd - 1] != UInt8(ascii: "\n") {
                copyEnd -= 1
            }
            if copyEnd > copyBegin {
                output += bytes[copyBegin..<copyEnd]
                if bytes[copyEnd - 1] != UInt8(ascii: "\n") { output.append(UInt8(ascii: "\n")) }
            }
            copyBegin = replaceEnd
            index += 1
        }
        if copyBegin < bytes.count { output += bytes[copyBegin...] }
        return output
    }

    /// `maybe_remove_section`: widens the cut at `seen[index]` to the whole
    /// section when the entry (with the ones that follow it in `seen`) is
    /// all the section holds and no comment is before or inside it.
    private func maybeRemoveSection(
        seen: [Int], key: [UInt8], begin: inout Int, end: inout Int, index: inout Int
    ) {
        // First, ensure that this is the first key, and that there are no
        // comments before the entry nor before the section header.
        var sectionSeen = false
        var position = index
        var start = seen[position]
        while start > 0 {
            let event = events[start - 1]
            if event.kind == .comment { return }
            if event.kind == .entry {
                if !sectionSeen { return }
                break
            }
            if event.kind == .section {
                if !event.isSection(of: key) { break }
                sectionSeen = true
            }
            start -= 1
        }
        let sectionBegin = events[start].begin

        // Next, make sure that we are removing the last key(s) in the
        // section, and that there are no comments that are possibly about
        // the current section.
        var next = seen[position] + 1
        scan: while next < events.count {
            switch events[next].kind {
            case .comment:
                return
            case .section:
                if events[next].isSection(of: key) {
                    next += 1
                    continue scan
                }
                break scan
            case .entry:
                position += 1
                if position < seen.count, next == seen[position] {
                    next += 1
                    continue scan
                }
                // There is another entry in this section.
                return
            case .whitespace:
                next += 1
            }
        }
        index = position
        begin = sectionBegin
        end = next < events.count ? events[next].begin : events[events.count - 1].end
    }
}
