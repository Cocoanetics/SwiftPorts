import Foundation
import ShellKit

/// git-lfs's SSH command precedence, translated to SSHKit's configuration
/// directives. No local executable or shell is launched by the SDK.
struct LFSSSHCommandOptions {
    var configPath: String
    var requireConfigFile = false
    var directives: [String] = []

    init(
        configuration: LFSConfiguration, configPath: String,
        environment: (String) -> String? = { Shell.env($0) }
    ) throws {
        self.configPath = configPath
        let command = environment("GIT_SSH_COMMAND") ?? ""
        let executable = environment("GIT_SSH") ?? ""
        let arguments: [String]
        let commandArguments = Self.fields(command)
        if !commandArguments.isEmpty {
            arguments = commandArguments
        } else if !executable.isEmpty {
            arguments = [executable]
        } else {
            arguments = Self.fields(configuration.get("core.sshcommand") ?? "ssh")
        }
        guard let executable = arguments.first else { return }
        // A process-based wrapper cannot be run over an in-process exec channel.
        let name = executable.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last?.lowercased()
        guard name == "ssh" || name == "ssh.exe" else {
            throw LFSClientError("SSHKit cannot execute SSH command: \(executable)")
        }
        let variant = environment("GIT_SSH_VARIANT") ?? configuration.get("ssh.variant") ?? "auto"
        if ["putty", "plink", "tortoiseplink"].contains(variant) {
            throw LFSClientError("SSHKit does not support SSH variant: \(variant)")
        }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let flag = String(argument.prefix(2))
            guard ["-F", "-i", "-o", "-p", "-l"].contains(flag) else {
                throw LFSClientError("SSHKit does not support SSH option: \(argument)")
            }
            let value: String
            if argument.count > 2 {
                value = String(argument.dropFirst(2))
            } else {
                index += 1
                guard index < arguments.count else {
                    throw LFSClientError("option requires an argument -- \(flag.dropFirst())")
                }
                value = arguments[index]
            }
            switch flag {
            case "-F": self.configPath = value; requireConfigFile = true
            case "-i": directives.append("IdentityFile \(Self.configQuote(value))")
            case "-p": directives.append("Port \(value)")
            case "-l": directives.append("User \(value)")
            default: directives.append(value)
            }
            index += 1
        }
    }

    private static func configQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Shell words in `GIT_SSH_COMMAND` / `core.sshCommand`.
    static func fields(_ command: String) -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !word.isEmpty { result.append(word); word = "" }
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { result.append(word) }
        return result
    }
}
