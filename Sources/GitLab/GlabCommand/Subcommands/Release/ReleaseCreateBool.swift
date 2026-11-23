import ArgumentParser

/// Value of `glab release create --no-update`. Upstream registers it as
/// a pflag bool, so bare `--no-update` means true and
/// `--no-update=false` means false; ``GlabCommand/preprocess(_:)``
/// rewrites the bare form to `--no-update=true`. Accepts exactly Go's
/// `strconv.ParseBool` spellings.
struct ReleaseCreateBool: ExpressibleByArgument, Equatable {
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
