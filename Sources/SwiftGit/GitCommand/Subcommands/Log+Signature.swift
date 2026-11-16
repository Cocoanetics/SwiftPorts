import Foundation
import SwiftGit

// Commit signatures in `git log` / `git show`, after git's `log-tree.c`
// (`show_signature`, `show_sig_lines`) and `pretty.c` (the `%G`
// placeholders).
extension Log {

    /// The `%G` placeholders git expands from a commit's signature.
    static let signaturePlaceholders: Set<Character> = ["G", "?", "S", "K", "F", "P", "T"]

    /// Whether `template` asks for any of them, so the signature has to
    /// be checked to format a commit.
    static func usesSignature(_ template: String) -> Bool {
        var characters = template.makeIterator()
        while let character = characters.next() {
            guard character == "%" else { continue }
            switch characters.next() {
            case "G": if let next = characters.next(), signaturePlaceholders.contains(next) { return true }
            default: continue
            }
        }
        return false
    }

    /// `entry` formatted with `template`, its `%G` placeholders filled
    /// in from `check` (an unsigned commit's being git's empty one).
    /// The text around them is formatted as before, so a signer holding
    /// a `%` stays as written.
    static func format(
        _ entry: LogEntry, _ template: String, signature check: SwiftGit.GitClient.SignatureCheck?
    ) -> String {
        let check = check ?? .unsigned
        var out = "", segment = ""
        var index = template.startIndex
        while index < template.endIndex {
            let rest = template[index...]
            if rest.hasPrefix("%%") {
                segment += "%%"
                index = template.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("%G"), rest.count > 2,
               let value = signatureValue(rest[rest.index(rest.startIndex, offsetBy: 2)], check) {
                out += entry.format(segment) + value
                segment = ""
                index = template.index(index, offsetBy: 3)
                continue
            }
            segment.append(template[index])
            index = template.index(after: index)
        }
        return out + (segment.isEmpty ? "" : entry.format(segment))
    }

    /// What `%G<placeholder>` expands to, `nil` for none git knows.
    private static func signatureValue(
        _ placeholder: Character, _ check: SwiftGit.GitClient.SignatureCheck
    ) -> String? {
        switch placeholder {
        case "G": return check.output ?? ""
        case "?": return String(check.verdict)
        case "S": return check.signer ?? ""
        case "K": return check.key ?? ""
        case "F": return check.fingerprint ?? ""
        case "P": return check.primaryKeyFingerprint ?? ""
        case "T": return check.trustLevel
        default: return nil
        }
    }

    /// git's `show_signature`: what checking the signature said, line by
    /// line, or `No signature` when it failed without a word. Nothing for
    /// an unsigned commit.
    static func signatureLines(_ check: SwiftGit.GitClient.SignatureCheck?) -> String {
        guard let check else { return "" }
        if !check.succeeded, check.output == nil { return "No signature\n" }
        return check.output ?? ""
    }

    /// What `--show-signature` shows after the `commit` line: git's
    /// `show_signature`, then its `show_mergetag` — each tag the commit
    /// merged, what it names, and what checking its signature said (or
    /// `No signature` when that failed without a word). `walked`: shown by
    /// `log`, whose revision walk has parsed the commit's parents.
    static func showSignatureLines(
        _ check: SwiftGit.GitClient.SignatureCheck?, commit: String, walked: Bool, client: SwiftGit.GitClient
    ) async throws -> String {
        var lines = signatureLines(check)
        for tag in try await client.mergeTags(commit, parentsParsed: walked) {
            lines += tag.description
            if let signature = tag.signature { lines += signature.output ?? "No signature\n" }
        }
        return lines
    }

    /// `--show-signature` / `--no-show-signature` among `positionals`
    /// (before any `--`), the last one winning over `flag`, then
    /// `log.showSignature`; the positionals without them.
    static func pullShowSignature(
        _ positionals: [String], flag: Bool?, client: SwiftGit.GitClient
    ) async throws -> (show: Bool, positionals: [String]) {
        var show = flag
        var rest: [String] = []
        var afterDoubleDash = false
        for argument in positionals {
            if argument == "--" { afterDoubleDash = true }
            if !afterDoubleDash, argument == "--show-signature" || argument == "--no-show-signature" {
                show = argument == "--show-signature"
            } else {
                rest.append(argument)
            }
        }
        if show == nil { show = try await client.configBool("log.showSignature") }
        return (show ?? false, rest)
    }
}
