enum SSHArgumentsParser {
    static let usage = """
        usage: ssh [-46AaCfGgKkMNnqsTtVvXxYyZ] [-B bind_interface] [-b bind_address]
                   [-c cipher_spec] [-D [bind_address:]port] [-E log_file]
                   [-e escape_char] [-F configfile] [-I pkcs11] [-i identity_file]
                   [-J destination] [-L address] [-l login_name] [-m mac_spec]
                   [-O ctl_cmd] [-o option] [-P tag] [-p port] [-R address]
                   [-S ctl_path] [-W host:port] [-w local_tun[:remote_tun]]
                   destination [command [argument ...]]
               ssh [-Q query_option]

        """

    static func parse(_ argv: [String]) throws -> SSHArguments {
        var index = 0
        var destination: String?
        var destinationHost: String?
        var command: [String] = []
        var optionsTerminated = false
        var port: Int?
        var user: String?
        var userConfigured = false
        var identityFiles: [String] = []
        var configOptions: [String] = []
        var configFile = "~/.ssh/config"
        var configFileWasSpecified = false
        var directives: [String] = []

        while index < argv.count {
            let argument = argv[index]

            if optionsTerminated {
                if destination == nil {
                    destination = argument
                    let split = try splitDestination(argument)
                    destinationHost = split.host
                    if let destinationUser = split.user, !userConfigured {
                        user = destinationUser
                        userConfigured = true
                        directives.append("User \(destinationUser)")
                    }
                    index += 1
                    command = Array(argv[index...])
                } else {
                    command = Array(argv[index...])
                }
                break
            }

            if argument == "--" {
                optionsTerminated = true
                index += 1
                continue
            }

            if argument.hasPrefix("-"), argument != "-" {
                let cluster = Array(argument.dropFirst())
                guard !cluster.isEmpty else {
                    throw SSHArgumentError.usage
                }

                var clusterIndex = 0
                while clusterIndex < cluster.count {
                    let option = cluster[clusterIndex]
                    switch option {
                    case "T":
                        // Exec channels never allocate a PTY, so this is already
                        // the command's effective behavior.
                        break
                    case "p", "l", "i", "o", "F":
                        let value: String
                        if clusterIndex + 1 < cluster.count {
                            value = String(cluster[(clusterIndex + 1)...])
                        } else {
                            index += 1
                            guard index < argv.count else {
                                throw SSHArgumentError.missingArgument(option)
                            }
                            value = argv[index]
                        }

                        switch option {
                        case "p":
                            guard let parsedPort = Int(value), (1...65_535).contains(parsedPort) else {
                                throw SSHArgumentError.badPort(value)
                            }
                            if port == nil {
                                port = parsedPort
                                directives.append("Port \(value)")
                            }
                        case "l":
                            if !userConfigured {
                                user = value
                                userConfigured = true
                                directives.append("User \(value)")
                            }
                        case "i":
                            identityFiles.append(value)
                            directives.append("IdentityFile \(quoted(value))")
                        case "o":
                            configOptions.append(value)
                            directives.append(value)
                            if !userConfigured, let optionUser = configurationValue(value, keyword: "user") {
                                user = optionUser
                                userConfigured = true
                            }
                        case "F":
                            configFile = value
                            configFileWasSpecified = true
                        default:
                            break
                        }

                        clusterIndex = cluster.count
                        continue
                    default:
                        throw SSHArgumentError.illegalOption(option)
                    }
                    clusterIndex += 1
                }
                index += 1
                continue
            }

            if destination == nil {
                destination = argument
                let split = try splitDestination(argument)
                destinationHost = split.host
                if let destinationUser = split.user, !userConfigured {
                    user = destinationUser
                    userConfigured = true
                    directives.append("User \(destinationUser)")
                }
                index += 1
                continue
            }

            command = Array(argv[index...])
            break
        }

        guard destination != nil, let destinationHost else {
            throw SSHArgumentError.usage
        }

        return SSHArguments(
            port: port,
            user: user,
            identityFiles: identityFiles,
            configOptions: configOptions,
            configFile: configFile,
            configFileWasSpecified: configFileWasSpecified,
            host: destinationHost,
            command: command,
            configurationDirectives: directives)
    }

    private static func splitDestination(_ destination: String) throws -> (user: String?, host: String) {
        guard !destination.isEmpty else {
            throw SSHArgumentError.usage
        }
        guard let at = destination.lastIndex(of: "@") else {
            return (nil, destination)
        }
        let user = String(destination[..<at])
        let host = String(destination[destination.index(after: at)...])
        guard !user.isEmpty, !host.isEmpty else {
            throw SSHArgumentError.usage
        }
        return (user, host)
    }

    private static func quoted(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: ""))\""
    }

    private static func configurationValue(_ option: String, keyword: String) -> String? {
        let parts = option.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == "=" || $0.isWhitespace })
        guard parts.count == 2, parts[0].lowercased() == keyword else {
            return nil
        }
        return String(parts[1])
    }
}
