import Foundation

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
            case "machine":
                if sawDefault { throw ParseError("bad default order") }
                if let current { machines.append(current) }
                current = NetrcMachine(name: tokens.next() ?? "", login: "", password: "")
            case "default":
                if let current { machines.append(current) }
                sawDefault = true
                current = NetrcMachine(name: "", login: "", password: "")
            case "login":
                current?.login = tokens.next() ?? ""
            case "password":
                current?.password = tokens.next() ?? ""
            case "account":
                _ = tokens.next()
            case "macdef":
                _ = tokens.next()
                // The macro body runs until a blank line. Tokens already dropped those.
            default:
                break
            }
        }
        if let current { machines.append(current) }
        return NetrcFile(machines: machines)
    }

    /// `$HOME/.netrc`, then `_netrc` on Windows. `nil` when the file can't be parsed
    /// (git-lfs then skips netrc). An absent file is an empty one.
    static func load(home: String?) -> NetrcFile? {
        guard let home, !home.isEmpty else { return NetrcFile(machines: []) }
        var names = [".netrc"]
        #if os(Windows)
        names.append("_netrc")
        #endif
        for name in names {
            let path = (home as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return try? parse(text)
        }
        return NetrcFile(machines: [])
    }

    /// Words split on whitespace, `#` comments to the end of the line, and
    /// double quotes keeping their spaces. Blank lines separate macros; we
    /// don't need the macro body.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoting = false
        var comment = false
        for character in text {
            if comment {
                if character == "\n" { comment = false }
                continue
            }
            if character == "#" && !quoting {
                comment = true
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            if character == "\"" {
                quoting.toggle()
                continue
            }
            if !quoting && character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
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
