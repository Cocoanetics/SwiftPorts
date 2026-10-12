import ShellKit

/// Tilde expansion shared by every file path this port reads (`ssh_config`, `known_hosts`,
/// identity files). Goes through `Shell.homeDirectory` rather than `NSHomeDirectory()`/`$HOME`
/// directly so it resolves correctly under a `ShellKit` sandbox (see `Docs/SSH.md`).
enum SSHPath {
    static func expandingTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return path
        }
        let home = Shell.homeDirectory.path
        if path == "~" {
            return home
        }
        return home + path.dropFirst(1)
    }
}
