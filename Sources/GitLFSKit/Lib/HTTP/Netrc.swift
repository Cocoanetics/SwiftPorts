import Foundation
import ShellKit

/// One `machine` (or `default`) from a netrc file (`git-lfs/go-netrc`).
struct NetrcMachine: Equatable, Sendable {
    var name: String
    var login: String
    var password: String
}

/// `~/.netrc` (and `_netrc` on Windows). A missing file is an empty finder.
/// `bad default order` — a `machine` after `default` — makes the helper unusable.
struct NetrcFile: Equatable, Sendable {
    var machines: [NetrcMachine]

    /// The first machine of `host` whose login matches when `login` is non-empty,
    /// otherwise the first machine of that host, otherwise `default`
    /// (an empty name), which matches even when the login does not.
    func find(host: String, login: String) -> NetrcMachine? {
        if let machine = machines.first(where: { $0.name == host && (login.isEmpty || login == $0.login) }) {
            return machine
        }
        return machines.first { $0.name.isEmpty }
    }

    static func parse(_ text: String) throws -> NetrcFile {
        var machines: [NetrcMachine] = []
        var current: NetrcMachine?
        var sawDefault = false
        var tokens = tokenize(text).makeIterator()
        while let token = tokens.next() {
            switch token {
            case .blank:
                continue
            case .word("machine"):
                if sawDefault { throw ParseError("bad default order") }
                if let current { machines.append(current) }
                current = NetrcMachine(name: nextWord(&tokens), login: "", password: "")
            case .word("default"):
                if let current { machines.append(current) }
                sawDefault = true
                current = NetrcMachine(name: "", login: "", password: "")
            case .word("login"):
                current?.login = nextWord(&tokens)
            case .word("password"):
                current?.password = nextWord(&tokens)
            case .word("account"):
                _ = nextWord(&tokens)
            case .word("macdef"):
                // The name, then the body through the blank line that ends it.
                // Words in the body are not login or password for the machine above.
                skipMacro(&tokens)
            case .word:
                break
            }
        }
        if let current { machines.append(current) }
        return NetrcFile(machines: machines)
    }

    /// The next word, or empty when the value is missing.
    private static func nextWord(_ tokens: inout IndexingIterator<[Token]>) -> String {
        guard case .word(let word) = tokens.next() else { return "" }
        return word
    }

    /// A `macdef` name, then every word until the blank line that ends the body.
    /// A body that runs to EOF is skipped too (`netrc` macros end at a blank line).
    private static func skipMacro(_ tokens: inout IndexingIterator<[Token]>) {
        if case .word = tokens.next() {
            while let body = tokens.next() {
                if case .blank = body { return }
            }
        }
    }

    /// `$HOME/.netrc`, then `_netrc` on Windows. `nil` when the file can't be parsed
    /// or the sandbox refuses it (git-lfs then skips netrc). An absent file is an empty one.
    static func load(home: String?) async -> NetrcFile? {
        guard let home, !home.isEmpty else { return NetrcFile(machines: []) }
        var names = [".netrc"]
        #if os(Windows)
        names.append("_netrc")
        #endif
        for name in names {
            let path = (home as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            // Denial has to win before the bytes are read. A refused
            // credential file is unusable, same as one that will not parse.
            do { try await Shell.authorize(url) } catch { return nil }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return try? parse(text)
        }
        return NetrcFile(machines: [])
    }

    enum Token: Equatable {
        case word(String)
        /// A blank line. A `macdef` body ends on one.
        case blank
    }

    /// Words split on whitespace, `#` comments to the end of the line, and
    /// double quotes keeping their spaces. A blank line is its own token so
    /// a `macdef` body can be skipped instead of parsed as credentials.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var quoting = false
        var comment = false
        var lineHasContent = false
        func flushWord() {
            guard !current.isEmpty else { return }
            tokens.append(.word(current))
            current = ""
            lineHasContent = true
        }
        for character in text {
            if comment {
                if character == "\n" {
                    comment = false
                    lineHasContent = false
                }
                continue
            }
            if character == "#" && !quoting {
                comment = true
                flushWord()
                lineHasContent = true
                continue
            }
            if character == "\"" {
                quoting.toggle()
                continue
            }
            if !quoting && character.isWhitespace {
                flushWord()
                if character == "\n" {
                    if !lineHasContent { tokens.append(.blank) }
                    lineHasContent = false
                }
                continue
            }
            lineHasContent = true
            current.append(character)
        }
        flushWord()
        return tokens
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// Hostname for netrc: a `host:port` uses the host only (`net.SplitHostPort`).
enum NetrcHost {
    static func name(of hostport: String) -> String? {
        guard hostport.contains(":") else { return hostport }
        if hostport.hasPrefix("["), let end = hostport.firstIndex(of: "]") {
            return String(hostport[hostport.index(after: hostport.startIndex)..<end])
        }
        guard let colon = hostport.lastIndex(of: ":") else { return hostport }
        let port = hostport[hostport.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
        return String(hostport[..<colon])
    }
}
