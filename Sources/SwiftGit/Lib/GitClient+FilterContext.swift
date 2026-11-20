import Foundation

extension GitClient {
    /// Explicit allowlist seam for config, metadata, raw blobs and refs.
    /// Mutating git operations still go through withRepository and cannot
    /// enter isolation on a filter-only client.
    func withFilterMetadataRepository<T>(_ body: (Repository) throws -> T) async throws -> T {
        if let filterContext {
            return try await filterContext.withRepository(self, body)
        }
        return try await withRepository(body)
    }
}
