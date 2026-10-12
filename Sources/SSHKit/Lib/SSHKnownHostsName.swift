/// The `known_hosts` name OpenSSH looks up and records a host under: the bare hostname for the
/// default port, or `[host]:port` otherwise. Mirrors `put_host_port()` in `misc.c` (lines
/// 801-810), which `sshconnect.c`'s `get_hostfile_hostname_ipaddr()` (line 697) uses to build the
/// `host` value `check_host_key()` matches against `known_hosts` with and prints in every
/// host-key-verification message.
enum SSHKnownHostsName {
    static func make(host: String, port: Int) -> String {
        guard port != 0, port != 22 else {
            return host
        }
        return "[\(host)]:\(port)"
    }
}
