import ArgumentParser

/// Value of `gh release edit`'s tri-state bool flags (`--draft`,
/// `--prerelease`, `--latest`, `--verify-tag`). Upstream registers
/// them as pflag bools, so `--draft` means true and `--draft=false`
/// means false; ``GhCommand/preprocess(_:)`` rewrites the bare form to
/// `--draft=true`. Accepts exactly Go's `strconv.ParseBool` spellings.
struct ReleaseEditBool: ExpressibleByArgument, Equatable {
    let value: Bool

    init(_ value: Bool) { self.value = value }

    init?(argument: String) {
        switch argument {
        case "1", "t", "T", "TRUE", "true", "True": value = true
        case "0", "f", "F", "FALSE", "false", "False": value = false
        default: return nil
        }
    }
}
