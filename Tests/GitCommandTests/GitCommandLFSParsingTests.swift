#if !os(Android)
import Testing
import ArgumentParser
@testable import GitCommand

@Suite("git lfs argv parsing")
struct GitCommandLFSParsingTests {
    private func parse(_ args: [String]) throws -> any ParsableCommand {
        let root = try #require(GitCommand.parseAsRoot(args) as? LFSCommand)
        return try LFSCommand.parseSubcommand(root.arguments)
    }

    @Test func group() throws {
        #expect(try GitCommand.parseAsRoot(["lfs"]) is LFSCommand)
        #expect(try parse(["lfs", "version"]) is LFSVersionCommand)
        let unknown = try #require(GitCommand.parseAsRoot(["lfs", "unknown"]) as? LFSCommand)
        #expect(unknown.arguments == ["unknown"])
    }

    @Test func pointer() throws {
        let command = try #require(parse(
            ["lfs", "pointer", "-f", "payload", "-p", "pointer", "--stdin", "--check", "--strict", "--no-strict"]
        ) as? LFSPointerCommand)
        #expect(command.file == "payload" && command.pointer == "pointer")
        #expect(command.stdin && command.check && command.strict && command.noStrict)
    }

    @Test func install() throws {
        let command = try #require(parse(
            ["lfs", "install", "-l", "-w", "--system", "--file=config", "-f", "-s", "--skip-repo", "-m"]
        ) as? LFSInstall)
        #expect(command.local && command.worktree && command.system && command.file == "config")
        #expect(command.force && command.skipSmudge && command.skipRepo && command.manual)
    }

    @Test func uninstall() throws {
        let command = try #require(parse(
            ["lfs", "uninstall", "--local", "--worktree", "--system", "--file", "config", "--skip-repo"]
        ) as? LFSUninstall)
        #expect(command.local && command.worktree && command.system && command.file == "config" && command.skipRepo)
        #expect(throws: (any Error).self) { try parse(["lfs", "uninstall", "--force"]) }
    }

    @Test func track() throws {
        let command = try #require(parse(
            ["lfs", "track", "*.bin", "-l", "--not-lockable", "-d", "-v", "--json", "--no-excluded",
             "--filename", "--no-modify-attrs", "a b"]
        ) as? LFSTrack)
        #expect(command.patterns == ["*.bin", "a b"])
        #expect(command.lockable && command.notLockable && command.dryRun && command.verbose)
        #expect(command.json && command.noExcluded && command.filename && command.noModifyAttrs)
        let untrack = try #require(parse(["lfs", "untrack", "--", "-file"]) as? LFSUntrack)
        #expect(untrack.patterns == ["-file"])
    }

    @Test(arguments: [
        ["-l", "-s", "-n", "-d", "-a", "-j", "-I", "*.bin", "-X", "skip/**"],
        ["--long", "--size", "--name-only", "--debug", "--all", "--json",
         "--include=*.bin", "--exclude=skip/**"]
    ])
    func lsFilesFlags(_ flags: [String]) throws {
        let command = try #require(parse(["lfs", "ls-files"] + flags) as? LFSLsFiles)
        #expect(command.long && command.size && command.nameOnly && command.debug && command.all && command.json)
        #expect(!command.deleted && command.refs.isEmpty)
        #expect(command.include == "*.bin" && command.exclude == "skip/**")
    }

    @Test func lsFilesDeletedAndRefs() throws {
        let debug = try #require(parse(["lfs", "ls-files", "-d"]) as? LFSLsFiles)
        #expect(debug.debug && !debug.deleted)
        let deleted = try #require(parse(["lfs", "ls-files", "--deleted", "HEAD"]) as? LFSLsFiles)
        #expect(deleted.deleted && !deleted.debug && deleted.refs == ["HEAD"])
        let literal = try #require(parse(["lfs", "ls-files", "A..B"]) as? LFSLsFiles)
        #expect(literal.refs == ["A..B"])
        let range = try #require(parse(["lfs", "ls-files", "A", "B"]) as? LFSLsFiles)
        #expect(range.refs == ["A", "B"])
    }
}
#endif
