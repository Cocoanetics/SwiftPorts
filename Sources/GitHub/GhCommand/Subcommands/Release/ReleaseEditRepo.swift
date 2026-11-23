import ArgumentParser
import GitHub

/// `gh release edit -R [HOST/]OWNER/REPO`. Unlike the plain
/// ``RepositoryReference`` argument, the host is kept so the lookup and
/// the PATCH reach the selected GitHub Enterprise instance (with its
/// token) instead of the default host.
struct ReleaseEditRepo: ExpressibleByArgument {
    let host: String?
    let reference: RepositoryReference

    init(host: String?, reference: RepositoryReference) {
        self.host = host
        self.reference = reference
    }

    init?(argument: String) {
        guard let reference = try? RepositoryReference(parsing: argument) else { return nil }
        let parts = argument.split(separator: "/")
        self.host = parts.count == 3 ? String(parts[0]) : nil
        self.reference = reference
    }
}
