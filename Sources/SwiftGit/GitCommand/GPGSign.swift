import ArgumentParser
import SwiftGit

/// git's `-S[<keyid>]`, `--gpg-sign[=<keyid>]` and `--no-gpg-sign`, as
/// `commit`, `merge`, `cherry-pick`, `rebase` and `pull` take them: an
/// optional value attached to the option, the last one given winning.
///
/// ArgumentParser has no optional-value options, so
/// ``GitCommand/preprocess(_:)`` spells every form as `--gpg-sign=` with a
/// tag: `+<keyid>` to sign (`+` alone with the default key), `-` not to.
/// A subcommand collects them with `@Option(name: .customLong("gpg-sign"))
/// var gpgSign: [String]` and reads them with ``mode(_:)``.
enum GPGSign {
    static let subcommands: Set<String> = ["commit", "merge", "cherry-pick", "rebase", "pull"]

    /// The options of each command that take the next argument as their
    /// value, whatever it looks like: `git commit -m -S` is a commit
    /// whose message is `-S`.
    static let valueOptions: [String: Set<String>] = [
        "commit": ["-m", "--message", "--author"],
        "merge": ["-m", "--message"],
        "pull": ["-m", "--message"],
        "rebase": ["--onto"]
    ]

    /// Whether the argument after `previous` is `previous`'s value.
    static func isValue(after previous: String?, in subcommand: String) -> Bool {
        guard let previous else { return false }
        return valueOptions[subcommand]?.contains(previous) == true
    }

    /// `argument` as the tagged `--gpg-sign=` value, `nil` when it isn't
    /// one of the forms.
    static func rewrite(_ argument: String) -> String? {
        if argument == "--no-gpg-sign" { return "--gpg-sign=-" }
        if argument == "--gpg-sign" { return "--gpg-sign=+" }
        if argument.hasPrefix("--gpg-sign=") { return "--gpg-sign=+" + argument.dropFirst("--gpg-sign=".count) }
        if argument.hasPrefix("-S") { return "--gpg-sign=+" + argument.dropFirst(2) }
        return nil
    }

    /// What the options given come to; `.config` with none.
    static func mode(_ values: [String]) -> SignMode {
        guard let last = values.last else { return .config }
        guard last.hasPrefix("+") else { return .noSign }
        let key = last.dropFirst()
        return .sign(keyID: key.isEmpty ? nil : String(key))
    }
}
