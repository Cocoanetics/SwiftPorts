#if os(macOS) || os(Linux)
import CGitKit
import CLibgit2Shim
import Foundation
import GitKit
import ShellKit
import Testing
@testable import SwiftGit

@Suite("config the environment asks for", .serialized)
struct EnvironmentConfigTests {

    /// The environment config reaches GitKit's own repository handle through
    /// reflection, since GitKit keeps it internal. If a GitKit release renames
    /// or hides the `pointer` property this fails, instead of commands under
    /// GIT_CONFIG_COUNT quietly reading the wrong config.
    @Test func reachesGitKitsRepositoryHandle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvironmentConfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try Repository.initialize(at: directory)
        let handle = try #require(GitClient.handle(of: repository))
        let path = try #require(git_repository_path(handle).map { String(cString: $0) })
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == directory.appendingPathComponent(".git").resolvingSymlinksInPath().path)
    }

    @Test func parsesTheCountedEntries() throws {
        #expect(try GitClient.commandLineConfig([:]).isEmpty)
        #expect(try GitClient.commandLineConfig(["GIT_CONFIG_COUNT": "0"]).isEmpty)
        let entries = try GitClient.commandLineConfig([
            "GIT_CONFIG_COUNT": "3",
            "GIT_CONFIG_KEY_0": "User.Name", "GIT_CONFIG_VALUE_0": "A=B",
            "GIT_CONFIG_KEY_1": "Remote.Origin.URL", "GIT_CONFIG_VALUE_1": "",
            "GIT_CONFIG_KEY_2": "a.b.c", "GIT_CONFIG_VALUE_2": "v",
            // Past the count: not read.
            "GIT_CONFIG_KEY_3": "x.y", "GIT_CONFIG_VALUE_3": "z"
        ])
        #expect(entries == ["user.name=A=B", "remote.Origin.url=", "a.b.c=v"])
    }

    @Test func refusesWhatGitRefuses() {
        func reason(_ variables: [String: String]) -> String? {
            do { _ = try GitClient.commandLineConfig(variables); return nil }
            catch let error as CommandLineConfigError { return error.reason }
            catch { return "\(error)" }
        }
        #expect(reason(["GIT_CONFIG_COUNT": "x"]) == "bogus count in GIT_CONFIG_COUNT")
        #expect(reason(["GIT_CONFIG_COUNT": "-1"]) == "too many entries in GIT_CONFIG_COUNT")
        #expect(reason(["GIT_CONFIG_COUNT": "1"]) == "missing config key GIT_CONFIG_KEY_0")
        #expect(reason(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a.b"])
                == "missing config value GIT_CONFIG_VALUE_0")
        #expect(reason(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "ab", "GIT_CONFIG_VALUE_0": ""])
                == "key does not contain a section: ab")
        #expect(reason(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "a.", "GIT_CONFIG_VALUE_0": ""])
                == "key does not contain variable name: a.")
        #expect(reason(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "", "GIT_CONFIG_VALUE_0": ""])
                == "empty config key")
        #expect(CommandLineConfigError(reason: "x").lines
                == ["error: x", "fatal: unable to parse command-line config"])
    }

    /// The count is read as git's `strtoul` reads it (checked against /usr/bin/git).
    @Test func readsTheCountAsStrtoulDoes() throws {
        func outcome(_ count: String) -> String {
            do { return "\(try GitClient.commandLineConfig(["GIT_CONFIG_COUNT": count]).count)" }
            catch let error as CommandLineConfigError { return error.reason }
            catch { return "\(error)" }
        }
        #expect(outcome("") == "0")
        #expect(outcome("-0") == "0")
        #expect(outcome("abc") == "bogus count in GIT_CONFIG_COUNT")
        #expect(outcome("3x") == "bogus count in GIT_CONFIG_COUNT")
        #expect(outcome("0x1") == "bogus count in GIT_CONFIG_COUNT")
        #expect(outcome("  ") == "bogus count in GIT_CONFIG_COUNT")
        #expect(outcome("-1") == "too many entries in GIT_CONFIG_COUNT")
        #expect(outcome("2147483648") == "too many entries in GIT_CONFIG_COUNT")
        #expect(outcome("99999999999999999999") == "too many entries in GIT_CONFIG_COUNT")
        #expect(outcome("-99999999999999999999") == "too many entries in GIT_CONFIG_COUNT")
        #expect(outcome(" 1") == "missing config key GIT_CONFIG_KEY_0")
        #expect(outcome("+1") == "missing config key GIT_CONFIG_KEY_0")
    }

    @Test func refusesKeysAsGitParsesThem() throws {
        func key(_ key: String) -> String {
            do { return try GitClient.normalizedKey(key) }
            catch let error as CommandLineConfigError { return error.reason }
            catch { return "\(error)" }
        }
        #expect(key(".b") == "key does not contain a section: .b")
        #expect(key("a b.c") == "invalid key: a b.c")
        #expect(key("a.b c") == "invalid key: a.b c")
        #expect(key("a.1b") == "invalid key: a.1b")
        #expect(key("1a.b") == "1a.b")
        #expect(key("A.B.C.D") == "a.B.C.d")
        #expect(key("a..b") == "a..b")
    }

    /// The overrides switch off the levels they replace and nothing more.
    @Test func overridesSwitchOffTheirLevels() async throws {
        Libgit2.ensureInitialized()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvironmentConfigLevels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let named = directory.appendingPathComponent("named.cfg")
        try "[a]\n\tb = c\n".write(to: named, atomically: true, encoding: .utf8)
        let shell = Shell(environment: Environment(
            variables: ["HOME": directory.path, "GIT_CONFIG_GLOBAL": "named.cfg", "GIT_CONFIG_SYSTEM": ""],
            workingDirectory: directory.path))
        try await shell.withCurrent {
            let client = GitClient(workingDirectory: directory)
            let plan = try await client.environmentConfig()
            #expect(plan.globalOverride)
            #expect(plan.globalFile == .init(typed: "named.cfg", resolved: directory.path + "/named.cfg"))
            #expect(plan.systemOverride)
            #expect(plan.systemFile == nil)
            #expect(plan.commandLine.isEmpty)
            try await client.isolatedGated {
                var buffer = [CChar](repeating: 1, count: 1024)
                for level in [GIT_CONFIG_LEVEL_GLOBAL, GIT_CONFIG_LEVEL_XDG, GIT_CONFIG_LEVEL_SYSTEM] {
                    #expect(swiftports_libgit2_get_search_path(Int32(level.rawValue), &buffer, buffer.count) == 0)
                    #expect(String(cString: buffer).isEmpty, "level \(level)")
                }
            }
        }
        // Without them the home's directories are searched.
        let plain = Shell(environment: Environment(variables: ["HOME": directory.path],
                                                   workingDirectory: directory.path))
        try await plain.withCurrent {
            let client = GitClient(workingDirectory: directory)
            try await client.isolatedGated {
                var buffer = [CChar](repeating: 0, count: 1024)
                let global = Int32(GIT_CONFIG_LEVEL_GLOBAL.rawValue)
                let xdg = Int32(GIT_CONFIG_LEVEL_XDG.rawValue)
                #expect(swiftports_libgit2_get_search_path(global, &buffer, buffer.count) == 0)
                #expect(String(cString: buffer) == directory.path)
                #expect(swiftports_libgit2_get_search_path(xdg, &buffer, buffer.count) == 0)
                #expect(String(cString: buffer) == directory.path + "/.config/git")
            }
        }
    }
}
#endif
