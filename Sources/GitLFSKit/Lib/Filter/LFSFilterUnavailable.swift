/// GitKit supplies the path, direction and driver in its filter-failed diagnostic.
struct LFSFilterUnavailable: Error, CustomStringConvertible {
    var description: String { "" }
}
