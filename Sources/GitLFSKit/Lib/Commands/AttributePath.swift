/// git-lfs `git/attribs.go` AttributePath, as used by track's listing.
struct AttributePath {
    let pattern: String
    let source: String
    let lineEnding: String
    let lockable: Bool
    let tracked: Bool
}
