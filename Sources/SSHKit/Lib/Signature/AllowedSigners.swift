import Foundation

/// OpenSSH allowed_signers lines. Malformed lines are diagnosed and skipped, as in sshsig.c.
public struct AllowedSigners: Sendable {
    struct Entry: Sendable {
        let principals: String
        let key: SSHPublicKey
        var namespaces: String?
        var after: Date?
        var before: Date?
        let line: Int
    }

    private let lines: [String]
    private let path: String

    public init(_ text: String, path: String) {
        self.path = path
        self.lines = text.components(separatedBy: .newlines)
    }

    /// Returns the first eligible line, the same stopping point as sshsig_find_principals.
    public func principals(
        for key: SSHPublicKey, principal: String? = nil, namespace: String? = nil,
        at time: Date = Date(), diagnostic: (String) -> Void = { _ in }
    ) -> [String] {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let principal, let patterns = trimmed.split(whereSeparator: { $0.isWhitespace }).first,
               !Self.matches(principal, String(patterns)) { continue }
            let entry: Entry
            do { entry = try Self.parse(trimmed, line: index + 1) }
            catch { diagnostic("\(path):\(index + 1): \(error)"); continue }
            if entry.key != key { continue }
            if let namespace, let patterns = entry.namespaces, !Self.matches(namespace, patterns) {
                diagnostic("\(path):\(entry.line): key is not permitted for use in signature "
                    + "namespace \"\(namespace)\"")
                continue
            }
            if let after = entry.after, time < after {
                diagnostic(timeDiagnostic(entry, time, bound: after, after: true))
                continue
            }
            if let before = entry.before, time > before {
                diagnostic(timeDiagnostic(entry, time, bound: before, after: false))
                continue
            }
            return entry.principals.split(separator: ",").map(String.init)
        }
        return []
    }

    private func timeDiagnostic(_ entry: Entry, _ time: Date, bound: Date, after: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let reason = after ? "is not yet valid" : "has expired"
        let relation = after ? "< valid-after" : "> valid-before"
        return "\(path):\(entry.line): key \(reason): verify time \(formatter.string(from: time)) "
            + "\(relation) \(formatter.string(from: bound))"
    }

    private static func matches(_ text: String, _ patterns: String) -> Bool {
        SSHPatternList.matches(host: text, tokens: patterns.split(separator: ",", omittingEmptySubsequences: false))
    }

    private static func parse(_ line: String, line number: Int) throws -> Entry {
        let fields = try split(line, separator: { $0.isWhitespace })
        guard fields.count >= 3 else { throw SSHKeygenError("invalid line") }
        let hasOptions = !fields[1].hasPrefix("ssh-") && !fields[1].hasPrefix("ecdsa-")
        let keyIndex = hasOptions ? 2 : 1
        guard fields.count > keyIndex + 1 else { throw SSHKeygenError("missing key") }
        let key = try SSHPublicKey(openSSHLine: fields[keyIndex] + " " + fields[keyIndex + 1])
        var entry = Entry(principals: fields[0], key: key, line: number)
        if !hasOptions { return entry }
        var seen: Set<String> = []
        for option in try split(fields[1], separator: { $0 == "," }, omitEmpty: false) {
            if option.lowercased() == "cert-authority" { throw SSHKeygenError("cert-authority is unsupported") }
            let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw SSHKeygenError("bad options: unknown key option")
            }
            let name = parts[0].lowercased()
            guard seen.insert(name).inserted else {
                throw SSHKeygenError("bad options: multiple \"\(name)\" clauses")
            }
            guard parts[1].hasPrefix("\"") else { throw SSHKeygenError("bad options: missing start quote") }
            guard parts[1].hasSuffix("\"") else { throw SSHKeygenError("bad options: unknown key option") }
            let value = String(parts[1].dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            switch name {
            case "namespaces": entry.namespaces = value
            case "valid-after": entry.after = try SSHKeygenTime.parse(value)
            case "valid-before": entry.before = try SSHKeygenTime.parse(value)
            default: throw SSHKeygenError("bad options: unknown key option")
            }
        }
        if let after = entry.after, let before = entry.before, before <= after {
            throw SSHKeygenError("bad options: \"valid-before\" time is before \"valid-after\"")
        }
        return entry
    }

    /// Delimit outside quotes, preserving quotes for the options pass.
    private static func split(
        _ text: String, separator: (Character) -> Bool, omitEmpty: Bool = true
    ) throws -> [String] {
        var quoted = false, escaped = false
        var result: [String] = [], field = ""
        for character in text {
            if character == "\"", !escaped { quoted.toggle() }
            if separator(character), !quoted {
                if !omitEmpty || !field.isEmpty { result.append(field); field = "" }
            } else { field.append(character) }
            escaped = character == "\\" && !escaped
        }
        guard !quoted else { throw SSHKeygenError("invalid options") }
        if !omitEmpty || !field.isEmpty { result.append(field) }
        return result
    }
}
