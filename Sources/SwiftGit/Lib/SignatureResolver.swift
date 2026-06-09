import Foundation
import ForgeKit
import ShellKit
import libgit2

/// Real-git-compatible identity resolution for commit author + committer.
///
/// Precedence (matches `man git-commit-tree` for each role):
/// 1. Explicit `override` parameter (e.g. `--author "Name <email>"`).
/// 2. Role-specific env vars (`GIT_AUTHOR_NAME` / `_EMAIL` / `_DATE`
///    for `.author`; `GIT_COMMITTER_*` for `.committer`).
/// 3. The other role's env vars when only one of name/email is set —
///    real git fills the missing piece from config, not the other role.
/// 4. `EMAIL` env var (only for the email half, only if config also empty).
/// 5. `git_signature_default(repo)` — repo-merged config user.name/.email.
///
/// libgit2's `git_signature_default` only does step 5; the env-var path
/// is what we add here for parity.
enum SignatureResolver {

    enum Role { case author, committer }

    /// Build a `git_signature` honoring env-var overrides. The returned
    /// pointer is owned by the caller and must be freed with
    /// `git_signature_free`.
    ///
    /// `override` lets the caller pin a name+email (e.g. `git commit
    /// --author`); env DATE still applies if set.
    static func resolve(
        role: Role,
        override: GitSignature? = nil,
        repo: OpaquePointer?,
        env: [String: String] = Shell.current.environment.variables
    ) throws -> UnsafeMutablePointer<git_signature>? {
        let prefix = role == .author ? "GIT_AUTHOR" : "GIT_COMMITTER"

        // Step 1: pick name + email.
        let envName = env["\(prefix)_NAME"]?.nilIfEmpty
        let envEmail = env["\(prefix)_EMAIL"]?.nilIfEmpty
        let dateString = env["\(prefix)_DATE"]?.nilIfEmpty

        // If the explicit `override` is set, use it as-is. Otherwise
        // merge env + config: env wins per-field; missing fields fall
        // back to git_signature_default.
        let name: String
        let email: String

        if let override {
            name = override.name
            email = override.email
        } else if envName != nil || envEmail != nil {
            // Partial env override: fetch defaults to fill the gaps.
            var def: UnsafeMutablePointer<git_signature>?
            let defRC = git_signature_default(&def, repo)
            let defaultName: String? = defRC == 0
                ? def.flatMap { $0.pointee.name.map { String(cString: $0) } }
                : nil
            let defaultEmail: String? = defRC == 0
                ? def.flatMap { $0.pointee.email.map { String(cString: $0) } }
                : nil
            if def != nil { git_signature_free(def) }

            // Fall back order for email: env → EMAIL var → config.
            let fallbackEmail = env["EMAIL"]?.nilIfEmpty ?? defaultEmail
            guard let resolvedName = envName ?? defaultName,
                  let resolvedEmail = envEmail ?? fallbackEmail else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "no name or email configured for \(role)")
            }
            name = resolvedName
            email = resolvedEmail
        } else if dateString != nil {
            // Only DATE was set in env — name+email come from config.
            var def: UnsafeMutablePointer<git_signature>?
            try check(git_signature_default(&def, repo))
            defer { git_signature_free(def) }
            name = def.flatMap { $0.pointee.name.map { String(cString: $0) } } ?? ""
            email = def.flatMap { $0.pointee.email.map { String(cString: $0) } } ?? ""
        } else {
            // No overrides at all — defer to libgit2's default.
            var def: UnsafeMutablePointer<git_signature>?
            try check(git_signature_default(&def, repo))
            return def
        }

        // Step 2: pick time. If GIT_*_DATE is set, parse it; else now.
        var sig: UnsafeMutablePointer<git_signature>?
        if let dateString,
           let parsed = parseGitDate(dateString) {
            try check(name.withCString { n in
                email.withCString { e in
                    git_signature_new(&sig, n, e, parsed.time, parsed.offsetMinutes)
                }
            })
        } else {
            try check(name.withCString { n in
                email.withCString { e in
                    git_signature_now(&sig, n, e)
                }
            })
        }
        return sig
    }

    /// Parse the date formats real git accepts in `GIT_AUTHOR_DATE` /
    /// `GIT_COMMITTER_DATE`. Currently supports:
    ///
    /// - Internal git form: `1700000000 +0100` (Unix seconds + tz offset)
    /// - ISO 8601 with offset: `2024-01-15T10:30:00+01:00`,
    ///   `2024-01-15 10:30:00 +0100`, `2024-01-15T10:30:00Z`.
    ///
    /// Skips real-git's relative ("yesterday", "2 days ago") and RFC
    /// 2822 forms — those are rarely used in env vars.
    static func parseGitDate(_ s: String) -> (time: git_time_t, offsetMinutes: Int32)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)

        // Internal `<unix-secs> ±HHMM` form.
        let parts = trimmed.split(separator: " ")
        if parts.count == 2, let secs = Int64(parts[0]),
           let offset = parseTZOffset(String(parts[1])) {
            return (git_time_t(secs), offset)
        }

        // ISO 8601 — try a couple of permissive formatter configurations.
        for fmt in isoFormatters {
            if let date = fmt.date(from: trimmed) {
                let offset = Self.tzOffsetMinutes(in: trimmed)
                return (git_time_t(Int(date.timeIntervalSince1970)), offset)
            }
        }
        return nil
    }

    private static let isoFormatters: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ssXXXXX",
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    /// Pull the trailing tz offset out of an ISO-8601-ish string and
    /// return it in minutes east of UTC. `Z` → 0.
    private static func tzOffsetMinutes(in s: String) -> Int32 {
        if s.hasSuffix("Z") || s.hasSuffix("z") { return 0 }
        // Match `±HH:MM` or `±HHMM` at the end.
        let regex = try? NSRegularExpression(pattern: #"([+-])(\d{2}):?(\d{2})$"#)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex?.firstMatch(in: s, range: range),
              let signR = Range(m.range(at: 1), in: s),
              let hR = Range(m.range(at: 2), in: s),
              let mR = Range(m.range(at: 3), in: s),
              let h = Int(s[hR]), let mi = Int(s[mR]) else {
            return 0
        }
        let total = h * 60 + mi
        return Int32(s[signR] == "-" ? -total : total)
    }

    private static func parseTZOffset(_ s: String) -> Int32? {
        guard s.count == 5, let sign = s.first,
              sign == "+" || sign == "-",
              let hh = Int(s.dropFirst().prefix(2)),
              let mm = Int(s.suffix(2))
        else { return nil }
        let total = hh * 60 + mm
        return Int32(sign == "-" ? -total : total)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
