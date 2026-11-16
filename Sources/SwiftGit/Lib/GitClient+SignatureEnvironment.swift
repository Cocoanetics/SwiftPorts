import Foundation
import GitKit

extension GitClient {

    /// The shell identity environment in the form GitKit's signature
    /// resolver accepts. Git fills a missing role email from `user.email`
    /// before consulting `EMAIL`; GitKit 2.10.1 reverses those two fallbacks.
    /// It also does not parse RFC 2822 dates, so convert that documented git
    /// date form to the equivalent raw timestamp before handing it off.
    internal func signatureEnvironment(for repository: Repository) throws -> [String: String] {
        var environment = shellEnvironment()

        if let configuredEmail = try repository.configGet("user.email"), !configuredEmail.isEmpty {
            for prefix in ["GIT_AUTHOR", "GIT_COMMITTER"]
                where environment["\(prefix)_NAME"]?.isEmpty == false
                    && environment["\(prefix)_EMAIL"]?.isEmpty != false {
                environment["\(prefix)_EMAIL"] = configuredEmail
            }
        }

        for key in ["GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE"] {
            if let value = environment[key], let normalized = Self.normalizedRFC2822Date(value) {
                environment[key] = normalized
            }
        }
        return environment
    }

    /// Convert `Thu, 07 Apr 2005 22:13:13 +0200` (git `%aD` / `%cD`)
    /// to `<unix-seconds> +0200`, retaining the explicitly supplied zone.
    private static func normalizedRFC2822Date(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard value.count > 5 else { return nil }
        let zone = String(value.suffix(5))
        guard let sign = zone.first, sign == "+" || sign == "-",
              let hours = Int(zone.dropFirst().prefix(2)), hours < 24,
              let minutes = Int(zone.suffix(2)), minutes < 60 else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        guard let date = formatter.date(from: value) else { return nil }
        return "\(Int64(date.timeIntervalSince1970)) \(zone)"
    }
}
