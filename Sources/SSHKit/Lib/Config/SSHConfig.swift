import Foundation
import ShellKit

/// A parsed `ssh_config(5)` file, resolved per destination host via `resolve(host:)`.
///
/// Implements the subset named in issue #112: `Host`, `HostName`, `Port`, `User`, `IdentityFile`,
/// `IdentitiesOnly`, `UserKnownHostsFile`, `StrictHostKeyChecking`. Every other real OpenSSH
/// keyword (`ForwardAgent`, `ProxyCommand`, `ciphers`, …) is recognized but has no effect — real
/// config files commonly set them, and a config keyword that OpenSSH itself accepts must not make
/// this parser fail the whole file. `Match` blocks are recognized but never match, since this port
/// doesn't evaluate `Match` conditionals (see Docs/SSH.md). Only a genuinely unknown token counts
/// as a bad option, mirroring `readconf.c`'s `process_config_line_depth` → `oBadOption` path.
public struct SSHConfig: Sendable {
    private let lines: [Substring]
    private let sourceDescription: String

    private init(lines: [Substring], sourceDescription: String) {
        self.lines = lines
        self.sourceDescription = sourceDescription
    }

    /// Parses in-memory config text (for tests/fixtures). `source` is used only in diagnostics.
    ///
    /// Splits on `Character.isNewline` (not a literal `"\n"`) so `\r\n`-terminated files parse
    /// identically to `\n`-terminated ones: Swift treats `\r\n` as a single `Character`, distinct
    /// from `"\n"` alone, so splitting on a literal `"\n"` silently fails to split CRLF content at
    /// all (seen on Windows CI, where checked-out fixtures get CRLF line endings).
    public static func parse(_ contents: String, source: String = "<config>") -> SSHConfig {
        SSHConfig(lines: contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline), sourceDescription: source)
    }

    /// Loads `path` (tilde-expanded). A missing file resolves to an empty config, matching
    /// `read_config_file_depth()`'s `fopen() == NULL → return 0` (not an error).
    public static func load(path: String) async throws -> SSHConfig {
        let expandedPath = SSHPath.expandingTilde(path)
        let url = Shell.resolve(expandedPath)
        try await Shell.authorize(url)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return SSHConfig(lines: [], sourceDescription: path)
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents, source: path)
    }

    /// Resolves every matching `Host` block's keywords against `host`, applying OpenSSH's
    /// first-value-wins rule (`readconf.c`'s `if (*activep && *intptr == -1) *intptr = value`
    /// pattern, e.g. lines 1237-1238, 1458-1459, 1596-1597) for single-value keywords, and
    /// accumulating `IdentityFile` across every matching block in file order (lines 1404-1422).
    public func resolve(host: String) throws -> SSHHostConfig {
        var hostName: String?
        var port: Int?
        var user: String?
        var identityFiles: [String] = []
        var identitiesOnly: Bool?
        var userKnownHostsFile: [String]?
        var strictHostKeyChecking: SSHStrictHostKeyChecking?
        var active = true
        var badOptionCount = 0

        for line in self.lines {
            guard let (keyword, args) = Self.tokenize(line) else {
                continue
            }

            switch keyword.lowercased() {
            case "host":
                active = SSHPatternList.matches(host: host, tokens: args)
            case "match":
                // Match conditionals are unimplemented; a Match block never applies.
                active = false
            case "hostname":
                if active, hostName == nil, let value = args.first {
                    hostName = String(value)
                }
            case "port":
                if active, port == nil, let value = args.first.flatMap({ Int($0) }) {
                    port = value
                } else if active, port == nil {
                    badOptionCount += 1
                }
            case "user":
                if active, user == nil, let value = args.first {
                    user = String(value)
                }
            case "identityfile":
                if active, let value = args.first {
                    identityFiles.append(String(value))
                }
            case "identitiesonly":
                if active, identitiesOnly == nil, let value = args.first.flatMap(Self.parseFlag) {
                    identitiesOnly = value
                } else if active, identitiesOnly == nil {
                    badOptionCount += 1
                }
            case "userknownhostsfile":
                if active, userKnownHostsFile == nil, !args.isEmpty {
                    userKnownHostsFile = args.map(String.init)
                }
            case "stricthostkeychecking":
                if active, strictHostKeyChecking == nil, let value = args.first {
                    if let parsed = SSHStrictHostKeyChecking(configValue: String(value)) {
                        strictHostKeyChecking = parsed
                    } else {
                        badOptionCount += 1
                    }
                }
            default:
                if !Self.recognizedButUnimplementedKeywords.contains(keyword.lowercased()) {
                    badOptionCount += 1
                }
            }
        }

        if badOptionCount > 0 {
            throw SSHError.badConfigurationOptions(path: self.sourceDescription, count: badOptionCount)
        }

        return SSHHostConfig(
            hostName: hostName ?? host,
            port: port ?? 22,
            user: user,
            identityFiles: identityFiles.isEmpty ? SSHHostConfig.defaultIdentityFiles : identityFiles,
            identitiesOnly: identitiesOnly ?? false,
            userKnownHostsFile: userKnownHostsFile ?? SSHHostConfig.defaultUserKnownHostsFiles,
            strictHostKeyChecking: strictHostKeyChecking ?? .ask
        )
    }

    // MARK: - Tokenizing

    /// Splits one config line into `(keyword, arguments)`, or `nil` for a blank/comment line.
    /// The keyword may be separated from its first argument by `=` or whitespace
    /// (`ssh_config(5)`: "Configuration options may be separated by whitespace or optional
    /// whitespace and exactly one `=`").
    private static func tokenize(_ line: Substring) -> (keyword: Substring, args: [Substring])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)[...]
        guard !trimmed.isEmpty, trimmed.first != "#" else {
            return nil
        }

        var rest = trimmed
        let keyword: Substring
        if let separatorIndex = rest.firstIndex(where: { $0 == "=" || $0.isWhitespace }) {
            keyword = rest[rest.startIndex..<separatorIndex]
            rest = rest[separatorIndex...]
            if rest.first == "=" {
                rest = rest.dropFirst()
            }
            rest = rest.drop(while: \.isWhitespace)
        } else {
            keyword = rest
            rest = ""
        }

        return (keyword, Self.splitArguments(rest))
    }

    /// Minimal whitespace splitter with double-quote support (`IdentityFile "~/my key"`),
    /// mirroring `argv_split()`'s handling of quoted arguments.
    private static func splitArguments(_ s: Substring) -> [Substring] {
        var args: [Substring] = []
        var current = ""
        var inQuotes = false
        var hasContent = false

        for char in s {
            if char == "\"" {
                inQuotes.toggle()
                hasContent = true
                continue
            }
            if char.isWhitespace, !inQuotes {
                if hasContent {
                    args.append(current[...])
                    current = ""
                    hasContent = false
                }
                continue
            }
            current.append(char)
            hasContent = true
        }
        if hasContent {
            args.append(current[...])
        }
        return args
    }

    private static func parseFlag(_ value: Substring) -> Bool? {
        switch value.lowercased() {
        case "yes", "true": return true
        case "no", "false": return false
        default: return nil
        }
    }

    /// Every other real `ssh_config(5)` keyword (`readconf.c`'s `keywords[]` table, lines
    /// 140-324), none of which this port implements. Recognizing them keeps real-world config
    /// files parseable instead of rejecting every file that sets, say, `ForwardAgent`.
    private static let recognizedButUnimplementedKeywords: Set<String> = [
        "protocol", "cipher", "fallbacktorsh", "globalknownhostsfile2", "rhostsauthentication",
        "userknownhostsfile2", "useroaming", "usersh", "useprivilegedport", "afstokenpassing",
        "kerberosauthentication", "kerberostgtpassing", "rsaauthentication", "rhostsrsaauthentication",
        "compressionlevel", "gssapiauthentication", "gssapidelegatecredentials", "smartcarddevice",
        "pkcs11provider", "forwardagent", "forwardx11", "forwardx11trusted", "forwardx11timeout",
        "exitonforwardfailure", "xauthlocation", "gatewayports", "passwordauthentication",
        "kbdinteractiveauthentication", "kbdinteractivedevices", "challengeresponseauthentication",
        "skeyauthentication", "tisauthentication", "pubkeyauthentication", "dsaauthentication",
        "hostbasedauthentication", "identityfile2", "certificatefile", "addkeystoagent", "identityagent",
        "hostkeyalias", "proxycommand", "ciphers", "macs", "remoteforward", "localforward",
        "permitremoteopen", "tag", "escapechar", "globalknownhostsfile", "connectionattempts",
        "batchmode", "checkhostip", "compression", "tcpkeepalive", "keepalive",
        "numberofpasswordprompts", "syslogfacility", "loglevel", "logverbose", "dynamicforward",
        "preferredauthentications", "hostkeyalgorithms", "casignaturealgorithms", "bindaddress",
        "bindinterface", "clearallforwardings", "enablesshkeysign", "verifyhostkeydns",
        "nohostauthenticationforlocalhost", "rekeylimit", "connecttimeout", "addressfamily",
        "serveraliveinterval", "serveralivecountmax", "sendenv", "setenv", "controlpath",
        "controlmaster", "controlpersist", "hashknownhosts", "include", "tunnel", "tunneldevice",
        "localcommand", "permitlocalcommand", "remotecommand", "visualhostkey", "kexalgorithms",
        "ipqos", "requesttty", "sessiontype", "stdinnull", "forkafterauthentication",
        "proxyusefdpass", "canonicaldomains", "canonicalizefallbacklocal", "canonicalizehostname",
        "canonicalizemaxdots", "canonicalizepermittedcnames", "streamlocalbindmask",
        "streamlocalbindunlink", "revokedhostkeys", "fingerprinthash", "updatehostkeys",
        "hostbasedacceptedalgorithms", "hostbasedkeytypes", "pubkeyacceptedalgorithms",
        "pubkeyacceptedkeytypes", "ignoreunknown", "proxyjump", "securitykeyprovider",
        "knownhostscommand", "requiredrsasize", "enableescapecommandline", "obscurekeystroketiming",
        "channeltimeout", "versionaddendum", "refuseconnection", "warnweakcrypto",
    ]
}
