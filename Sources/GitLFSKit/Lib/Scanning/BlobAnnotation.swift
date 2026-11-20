/// Unrendered `command_status.go` blob information, retaining full hashes.
enum BlobAnnotation: Sendable, Equatable {
    case lfs(String)
    case git(String)
    case file(String)
    case missing
    case deleted
}
