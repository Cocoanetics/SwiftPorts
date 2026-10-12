/// `ssh_config(5)`'s `StrictHostKeyChecking` values, `readconf.c`'s `multistate_strict_hostkey`
/// table (lines 1006-1016): `yes`/`true` → `.yes`, `no`/`false`/`off` → `.no`, `ask` → `.ask`,
/// `accept-new` → `.acceptNew`. The real client's default, when unset, is `.ask`
/// (`readconf.c` line 2912).
public enum SSHStrictHostKeyChecking: Sendable, Equatable {
    /// Refuse unknown host keys outright; never prompt.
    case yes

    /// Accept and silently record any host key, known or not.
    case no

    /// Prompt for unknown host keys; refuse changed ones. The default.
    case ask

    /// Silently accept and record new host keys; still refuse changed ones.
    case acceptNew

    public init?(configValue: String) {
        switch configValue.lowercased() {
        case "yes", "true": self = .yes
        case "no", "false", "off": self = .no
        case "ask": self = .ask
        case "accept-new": self = .acceptNew
        default: return nil
        }
    }
}
