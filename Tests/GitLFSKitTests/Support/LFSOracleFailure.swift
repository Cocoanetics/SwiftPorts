#if os(macOS) || os(Linux)
/// A command the oracle ran that failed.
struct LFSOracleFailure: Error, CustomStringConvertible {
    let description: String
}
#endif
