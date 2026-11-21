import Foundation

/// Worktree files the synchronous diff pass must not hash until the async
/// sandbox gate has approved them. Thrown before rename detection reads them.
struct DiffIndexReadAuthorization: Error {
    let urls: [URL]
}
