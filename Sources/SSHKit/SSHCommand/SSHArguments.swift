/// `ssh(1)`'s `options.request_tty` (`readconf.h`): whether `-t`/`-T` were given, and how many
/// times — a second `-t` forces a PTY even without a local terminal (`ssh.c`'s `case 't'`).
enum SSHRequestTTY: Equatable {
    case auto
    case no
    case yes
    case force
}

struct SSHArguments: Equatable {
    var port: Int?
    var user: String?
    var identityFiles: [String]
    var configOptions: [String]
    var configFile: String
    var configFileWasSpecified: Bool
    var host: String
    var command: [String]
    var configurationDirectives: [String]
    var requestTTY: SSHRequestTTY
}
