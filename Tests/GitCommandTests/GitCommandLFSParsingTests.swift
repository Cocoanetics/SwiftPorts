#if !os(Android)
import Foundation
import Testing
import ArgumentParser
import ShellKit
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
        let env = try #require(parse(["lfs", "env", "ignored", "arguments"]) as? LFSEnvCommand)
        #expect(env.arguments == ["ignored", "arguments"])
        let unknown = try #require(GitCommand.parseAsRoot(["lfs", "unknown"]) as? LFSCommand)
        #expect(unknown.arguments == ["unknown"])
    }

    @Test func environmentRepositorySelection() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("outside")
        let repository = root.appendingPathComponent("repository")
        let shell = Shell(environment: Environment(variables: [
            "GIT_DIR": "../repository/.git", "GIT_WORK_TREE": "../repository"
        ], workingDirectory: outside.path))
        let client = await shell.withCurrent { CommandContext.lfsEnvironmentGitClient() }
        #expect(client.workingDirectory.standardizedFileURL == repository.standardizedFileURL)
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

    @Test(arguments: [["-p", "-j"], ["--porcelain", "--json"]])
    func statusFlags(_ flags: [String]) throws {
        let command = try #require(parse(["lfs", "status", "ignored"] + flags + ["arguments"]) as? LFSStatus)
        #expect(command.porcelain && command.json)
        #expect(command.arguments == ["ignored", "arguments"])
        let plain = try #require(parse(["lfs", "status"]) as? LFSStatus)
        #expect(!plain.porcelain && !plain.json && plain.arguments.isEmpty)
    }

    @Test(arguments: [
        ["-a", "-I", "*.bin", "-X", "skip/**", "-d", "-j"],
        ["-a", "-I*.bin", "-Xskip/**", "-d", "-j"],
        ["--all", "--include=*.bin", "--exclude=skip/**", "--dry-run", "--json"]
    ])
    func fetchFlags(_ flags: [String]) throws {
        let command = try #require(parse(["lfs", "fetch", "origin"] + flags + ["main", "tag"]) as? LFSFetch)
        #expect(command.all && command.dryRun && command.json)
        #expect(command.include == "*.bin" && command.exclude == "skip/**")
        #expect(command.arguments == ["origin", "main", "tag"])
        let defaults = try #require(parse(["lfs", "fetch"]) as? LFSFetch)
        #expect(defaults.arguments.isEmpty && defaults.include == nil && defaults.exclude == nil)
        let empty = try #require(parse(["lfs", "fetch", "--include="]) as? LFSFetch)
        #expect(empty.include == "")
        let literal = try #require(parse(["lfs", "fetch", "--", "--include="]) as? LFSFetch)
        #expect(literal.arguments == ["--include="] && literal.include == nil)
        let value = try #require(parse(["lfs", "fetch", "-I", "--include="]) as? LFSFetch)
        #expect(value.include == "--include=")
    }

    @Test(arguments: ["--recent", "-r", "--prune", "-p", "--refetch"])
    func unsupportedFetchOptions(_ flag: String) {
        #expect(throws: (any Error).self) { try parse(["lfs", "fetch", flag]) }
    }

    @Test(arguments: [["-a", "-d", "-o"], ["--all", "--dry-run", "--object-id"]])
    func pushFlags(_ flags: [String]) throws {
        let command = try #require(parse(["lfs", "push", "origin"] + flags + ["--stdin"]) as? LFSPush)
        #expect(command.all && command.dryRun && command.objectID && command.stdin)
        #expect(command.arguments == ["origin"])
        // Cobra accepts these together; the SDK emits the status-1 stdout diagnostic at runtime.
        let conflict = try #require(parse(["lfs", "push", "origin", "main", "--stdin"]) as? LFSPush)
        #expect(conflict.stdin && conflict.arguments == ["origin", "main"])
    }

    @Test(arguments: ["-d", "--dry-run"])
    func prePushFlags(_ flag: String) throws {
        let command = try #require(parse(["lfs", "pre-push", "origin", "url", flag]) as? LFSPrePush)
        #expect(command.dryRun && command.arguments == ["origin", "url"])
        #expect(throws: (any Error).self) { try parse(["lfs", "pre-push", "--stdin"]) }
    }

    #if os(macOS) || os(Linux)
    @Test func transferDispatchAndDiagnostics() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        #expect(try fixture.system(["config", "remote.origin.url", "https://example.invalid/repo.git"],
                                   in: fixture.ours).status == 0)
        let push = try await fixture.run(["push"])
        #expect(push.status == 1 && push.stderr.isEmpty)
        #expect(push.stdout == "Specify a remote and a remote branch name (`git lfs push origin main`)\n")
        let conflict = try await fixture.run(["push", "origin", "main", "--stdin"])
        #expect(conflict.status == 1 && conflict.stderr.isEmpty)
        #expect(conflict.stdout == "Further command line arguments are ignored with --stdin\n")
        let noRefs = try await fixture.run(["push", "origin"])
        #expect(noRefs.status == 1 && noRefs.stderr.isEmpty)
        #expect(noRefs.stdout == "At least one ref must be supplied without --all\n")
        let noOIDs = try await fixture.run(["push", "origin", "--object-id"])
        #expect(noOIDs.status == 1 && noOIDs.stderr.isEmpty)
        #expect(noOIDs.stdout == "At least one object ID must be supplied with --object-id\n")
        let hook = try await fixture.run(["pre-push"])
        #expect(hook.status == 1 && hook.stderr.isEmpty)
        #expect(hook.stdout == "This should be run through Git's pre-push hook.  Run `git lfs update` to install it.\n")
        let invalid = try await fixture.run(["fetch", "main"])
        #expect(invalid.status == 2 && invalid.stdout.isEmpty)
        let cwd = fixture.ours.path
        #expect(invalid.stderr == "Invalid remote name \"main\": invalid remote name: \"\(cwd)/main\"\n")
        let fetch = try await fixture.run(["fetch", "--all", "--json"])
        #expect(fetch.status == 0 && fetch.stdout == "{\n \"transfers\": []\n}\n")
        let emptyInput = try await fixture.run(["push", "origin", "--stdin", "--object-id"])
        #expect(emptyInput.status == 0)
        let deletion = "refs/heads/main \(String(repeating: "0", count: 40)) refs/heads/main "
            + String(repeating: "0", count: 40) + "\n"
        let prePush = try await fixture.run(["pre-push", "origin", "ignored-url", "-d"], input: Data(deletion.utf8))
        #expect(prePush.status == 0 && prePush.stdout.isEmpty && prePush.stderr.isEmpty)
    }
    #endif
}
#endif
