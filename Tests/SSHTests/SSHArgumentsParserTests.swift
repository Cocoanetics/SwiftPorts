#if !os(Android)
import Testing
@testable import SSHCommand

@Suite("ssh argv parsing")
struct SSHArgumentsParserTests {
    @Test("parses the supported option subset and preserves the remote command")
    func supportedOptions() throws {
        let parsed = try SSHArgumentsParser.parse([
            "-p", "2222", "-l", "alice", "-i", "first key",
            "-isecond", "-o", "StrictHostKeyChecking=yes",
            "-F", "custom_config", "-T", "-tt", "-vvv",
            "example.com", "printf", "-%s", "hello",
        ])

        #expect(parsed.port == 2222)
        #expect(parsed.user == "alice")
        #expect(parsed.identityFiles == ["first key", "second"])
        #expect(parsed.configOptions == ["StrictHostKeyChecking=yes"])
        #expect(parsed.configFile == "custom_config")
        #expect(parsed.requestTTY == .force)
        #expect(parsed.verbosity == 3)
        #expect(parsed.host == "example.com")
        #expect(parsed.command == ["printf", "-%s", "hello"])
    }

    @Test("user at host supplies the user unless -l already did")
    func destinationUser() throws {
        let inferred = try SSHArgumentsParser.parse(["bob@example.com", "true"])
        #expect(inferred.user == "bob")
        #expect(inferred.host == "example.com")

        let explicit = try SSHArgumentsParser.parse(["-l", "alice", "bob@example.com", "true"])
        #expect(explicit.user == "alice")
        #expect(explicit.host == "example.com")

        let optionFirst = try SSHArgumentsParser.parse([
            "-o", "User=carol", "bob@example.com", "true",
        ])
        #expect(optionFirst.user == "carol")

        let destinationFirst = try SSHArgumentsParser.parse([
            "bob@example.com", "-l", "carol", "true",
        ])
        #expect(destinationFirst.user == "bob")
    }

    @Test("options may follow the destination until the command starts")
    func optionsAfterDestination() throws {
        let parsed = try SSHArgumentsParser.parse([
            "example.com", "-p2222", "-v", "echo", "-n", "hello",
        ])
        #expect(parsed.port == 2222)
        #expect(parsed.verbosity == 1)
        #expect(parsed.command == ["echo", "-n", "hello"])
    }

    @Test("double dash terminates option parsing")
    func optionTerminator() throws {
        let parsed = try SSHArgumentsParser.parse(["--", "example.com", "-v"])
        #expect(parsed.verbosity == 0)
        #expect(parsed.command == ["-v"])
    }

    @Test("first port and login option win")
    func firstValueWins() throws {
        let parsed = try SSHArgumentsParser.parse([
            "-p", "22", "-p", "2200", "-l", "first", "-l", "second",
            "example.com", "true",
        ])
        #expect(parsed.port == 22)
        #expect(parsed.user == "first")
    }

    @Test("unknown and incomplete options use getopt-shaped errors")
    func optionErrors() {
        #expect(throws: SSHArgumentError.illegalOption("z")) {
            _ = try SSHArgumentsParser.parse(["-z", "example.com", "true"])
        }
        #expect(throws: SSHArgumentError.missingArgument("p")) {
            _ = try SSHArgumentsParser.parse(["-p"])
        }
        #expect(throws: SSHArgumentError.badPort("nope")) {
            _ = try SSHArgumentsParser.parse(["-p", "nope", "example.com", "true"])
        }
    }

    @Test("missing or malformed destinations print usage")
    func destinationErrors() {
        #expect(throws: SSHArgumentError.usage) {
            _ = try SSHArgumentsParser.parse([])
        }
        #expect(throws: SSHArgumentError.usage) {
            _ = try SSHArgumentsParser.parse(["@example.com", "true"])
        }
    }
}
#endif
