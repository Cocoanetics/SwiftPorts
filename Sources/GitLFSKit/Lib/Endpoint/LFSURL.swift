import Foundation

/// Enough of Go's `net/url` for the URLs git-lfs derives endpoints from.
/// Foundation's `URL` rewrites `https://host` with a trailing slash and
/// does not treat `git@host:path` the way `net/url.Parse` does.
struct LFSURL: Equatable, Sendable {
    var scheme = ""
    var username: String?
    var password: String?
    /// Hostname without a port, brackets stripped.
    var host = ""
    var port = ""
    /// Decoded path, including a leading `/` when the URL had one.
    var path = ""
    var rawQuery = ""

    /// `url.URL.Host`: an IPv6 address stays in brackets, with `:port` when set.
    /// A bare `2001:db8::1` is not a host; parsers stop at the first colon.
    var hostPort: String {
        let name = host.contains(":") ? "[\(host)]" : host
        guard !port.isEmpty else { return name }
        return "\(name):\(port)"
    }

    var hasPassword: Bool { password != nil }

    /// `url.URL.String` for the forms git-lfs prints.
    func string() -> String {
        var text = ""
        if !scheme.isEmpty {
            text += scheme + "://"
        }
        if let username, !username.isEmpty {
            text += Self.escape(username, mode: .user)
            if let password { text += ":" + Self.escape(password, mode: .user) }
            text += "@"
        }
        text += hostPort
        text += Self.escape(path, mode: .path)
        if !rawQuery.isEmpty { text += "?" + rawQuery }
        return text
    }

    /// `(&url.URL{Path: path}).EscapedPath()`.
    static func escapedPath(_ path: String) -> String { escape(path, mode: .path) }

    /// The scheme `net/url` would accept before the first colon, or nil
    /// (`git@host:path` is not a scheme: `@` is not a scheme character).
    static func scheme(of raw: String) -> String? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let before = raw[..<colon]
        guard !before.contains("/"), let first = before.first, isLetter(first) else { return nil }
        for character in before.dropFirst() {
            let mark = character == "+" || character == "-" || character == "."
            guard isLetter(character) || isDigit(character) || mark else {
                return nil
            }
        }
        return before.lowercased()
    }

    /// Parse `raw`. A string Go would reject as a URL comes back with an empty scheme
    /// and the raw text as its path.
    static func parse(_ raw: String) -> LFSURL {
        var body = raw
        if let hash = body.firstIndex(of: "#") { body = String(body[..<hash]) }
        var query = ""
        if let question = body.firstIndex(of: "?") {
            query = String(body[body.index(after: question)...])
            body = String(body[..<question])
        }
        if body.hasPrefix("//") {
            var url = LFSURL()
            url.rawQuery = query
            var rest = body
            rest.removeFirst(2)
            let pathStart = rest.firstIndex(of: "/")
            let authority = pathStart.map { String(rest[..<$0]) } ?? rest
            url.path = pathStart.map { percentDecode(String(rest[$0...])) } ?? ""
            parseAuthority(authority, into: &url)
            return url
        }
        guard let scheme = scheme(of: body), let colon = body.firstIndex(of: ":") else {
            var url = LFSURL()
            url.path = percentDecode(body)
            url.rawQuery = query
            return url
        }
        var url = LFSURL()
        url.scheme = scheme
        url.rawQuery = query
        var rest = String(body[body.index(after: colon)...])
        guard rest.hasPrefix("//") else {
            url.path = percentDecode(rest)
            return url
        }
        rest.removeFirst(2)
        let pathStart = rest.firstIndex(of: "/")
        let authority = pathStart.map { String(rest[..<$0]) } ?? rest
        url.path = pathStart.map { percentDecode(String(rest[$0...])) } ?? ""
        parseAuthority(authority, into: &url)
        return url
    }

    private static func parseAuthority(_ authority: String, into url: inout LFSURL) {
        var hostport = authority
        if let at = authority.lastIndex(of: "@") {
            let userinfo = String(authority[..<at])
            hostport = String(authority[authority.index(after: at)...])
            if let colon = userinfo.firstIndex(of: ":") {
                url.username = percentDecode(String(userinfo[..<colon]))
                url.password = percentDecode(String(userinfo[userinfo.index(after: colon)...]))
            } else if !userinfo.isEmpty {
                url.username = percentDecode(userinfo)
            }
        }
        if hostport.hasPrefix("[") {
            if let end = hostport.firstIndex(of: "]") {
                url.host = String(hostport[hostport.index(after: hostport.startIndex)..<end])
                let after = hostport.index(after: end)
                if after < hostport.endIndex && hostport[after] == ":" {
                    url.port = String(hostport[hostport.index(after: after)...])
                }
            }
            return
        }
        if let colon = hostport.lastIndex(of: ":"), hostport[colon...].dropFirst().allSatisfy(isDigit) {
            url.host = String(hostport[..<colon])
            url.port = String(hostport[hostport.index(after: colon)...])
        } else {
            url.host = hostport
        }
    }

    /// `path.Ext`: the suffix from the last dot in the final path element.
    static func pathExtension(_ path: String) -> String {
        var index = path.endIndex
        while index > path.startIndex {
            let previous = path.index(before: index)
            let character = path[previous]
            if character == "/" { break }
            #if os(Windows)
            if character == "\\" { break }
            #endif
            if character == "." { return String(path[previous...]) }
            index = previous
        }
        return ""
    }

    enum EscapeMode { case path, user }

    /// Go's `shouldEscape` for `encodePath` and `encodeUserPassword`.
    static func escape(_ text: String, mode: EscapeMode) -> String {
        var out = ""
        for byte in text.utf8 {
            if !shouldEscape(byte, mode: mode) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func shouldEscape(_ byte: UInt8, mode: EscapeMode) -> Bool {
        if byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") { return false }
        if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") { return false }
        if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") { return false }
        switch byte {
        case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
            return false
        case UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "+"), UInt8(ascii: ","),
             UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: ";"), UInt8(ascii: "="),
             UInt8(ascii: "?"), UInt8(ascii: "@"):
            switch mode {
            case .path:
                return byte == UInt8(ascii: "?")
            case .user:
                return byte == UInt8(ascii: "@") || byte == UInt8(ascii: "/")
                    || byte == UInt8(ascii: "?") || byte == UInt8(ascii: ":")
            }
        default:
            return true
        }
    }

    static func percentDecode(_ text: String) -> String {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "%",
               let first = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               first < text.endIndex,
               let second = text.index(after: first) as String.Index?,
               second < text.endIndex,
               let high = hex(text[first]), let low = hex(text[second]) {
                bytes.append(high << 4 | low)
                index = text.index(after: second)
                continue
            }
            bytes.append(contentsOf: String(character).utf8)
            index = text.index(after: index)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hex(_ character: Character) -> UInt8? {
        guard let scalar = character.unicodeScalars.first, scalar.value < 128 else { return nil }
        let byte = UInt8(scalar.value)
        if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") { return byte - UInt8(ascii: "0") }
        if byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f") { return byte - UInt8(ascii: "a") + 10 }
        if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F") { return byte - UInt8(ascii: "A") + 10 }
        return nil
    }

    private static func isLetter(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private static func isDigit(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return value >= 48 && value <= 57
    }
}
