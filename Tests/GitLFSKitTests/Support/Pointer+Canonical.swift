@testable import GitLFSKit

extension Pointer {
    /// The pointer, marked (non-)canonical.
    func withCanonical(_ canonical: Bool) -> Pointer {
        var copy = self
        copy.canonical = canonical
        return copy
    }
}
