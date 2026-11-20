/// Include/exclude paths using git-lfs's `filepathfilter` GitIgnore mode.
/// An empty include list allows everything; excludes always take precedence.
public struct FilepathFilter: Sendable {
    public let include: [String]
    public let exclude: [String]

    private let includes: [FilepathPattern]
    private let excludes: [FilepathPattern]

    public init(include: [String] = [], exclude: [String] = []) {
        self.include = include
        self.exclude = exclude
        includes = include.map(FilepathPattern.init)
        excludes = exclude.map(FilepathPattern.init)
    }

    public func allows(_ path: String) -> Bool {
        (includes.isEmpty || includes.contains { $0.matches(path) })
            && !excludes.contains { $0.matches(path) }
    }
}
