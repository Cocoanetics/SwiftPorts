import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

struct Merge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Join two or more development histories together."
    )

    @Flag(name: .customLong("ff"),
          help: "Allow fast-forward (the default).")
    var ff: Bool = false

    @Flag(name: .customLong("no-ff"),
          help: "Always create a merge commit, even when fast-forward is possible.")
    var noFF: Bool = false

    @Flag(name: .customLong("ff-only"),
          help: "Refuse to merge unless fast-forward is possible.")
    var ffOnly: Bool = false

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Override the auto-generated merge commit message.")
    var message: String?

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress the merge summary; conflicts are still reported.")
    var quiet: Bool = false

    @Argument(help: "Commits to merge into the current branch; more than one make an octopus merge.")
    var refs: [String] = []

    func validate() throws {
        let count = [ff, noFF, ffOnly].filter { $0 }.count
        if count > 1 {
            throw ValidationError("only one of --ff / --no-ff / --ff-only may be set")
        }
        if refs.isEmpty {
            throw ValidationError("Missing expected argument '<refs> ...'")
        }
    }

    func run() async throws {
        let mode: FastForwardMode = noFF ? .never : (ffOnly ? .onlyFastForward : .auto)
        let client = CommandContext.gitClient()

        // A merge needs a work tree.
        if try await client.toplevel() == nil {
            throw CLIError.stderr("fatal: this operation must be run in a work tree", exitCode: 128)
        }

        // git won't start a merge while another waits to be concluded.
        if let gitDir = try await client.gitDir() {
            for (file, operation) in [("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick")]
            where FileManager.default.fileExists(atPath: gitDir + "/" + file) {
                // The second line is advice, which advice.resolveConflict
                // (or GIT_ADVICE) turns off.
                var advise = try await client.configBool("advice.resolveConflict") ?? true
                if advise, let environment = Shell.current.environment["GIT_ADVICE"] {
                    advise = try SwiftGit.GitClient.parseGitBoolEnvironment(environment, name: "GIT_ADVICE")
                }
                throw CLIError.stderr(["fatal: You have not concluded your \(operation) (\(file) exists)."]
                                      + (advise ? ["Please, commit your changes before you merge."] : []),
                                      exitCode: 128)
            }
        }

        guard refs.count == 1, let ref = refs.first else {
            let heads: MergeHeads
            do {
                heads = try await client.mergeHeads(reducing: refs)
            } catch let err as Libgit2Error where err.message.hasSuffix("not something we can merge") {
                throw CLIError.stderr(err.message, exitCode: 1)
            }
            // An unborn branch takes one commit: what's left once reduced.
            if heads.heads.count > 1, (try? await client.resolveOID("HEAD")) == nil {
                throw CLIError.stderr("fatal: Can merge only exactly one commit into empty head", exitCode: 128)
            }
            // Each head's name, and its object, so an annotated tag's
            // message follows the title.
            var names: [String] = [], objects: [String] = []
            for head in heads.heads {
                names.append(try await client.mergeName(head))
                objects.append(try await client.resolveOID(head))
            }
            var message = self.message
            if message == nil { message = try await client.mergeMessage(describing: names, objects: objects) }
            try await Self.merge(heads: heads, mode: mode, message: message ?? "", client: client, quiet: quiet)
            return
        }

        let outcome: MergeOutcome
        do {
            outcome = try await client.merge(
                ref: ref, fastForward: mode, message: message, author: nil)
        } catch let err as Libgit2Error
            where err.message.contains("not something we can merge") {
            throw CLIError.stderr(
                "merge: \(ref) - not something we can merge", exitCode: 1)
        } catch let err as Libgit2Error
            where err.message.contains("Not possible to fast-forward") {
            throw CLIError.stderr(
                "fatal: Not possible to fast-forward, aborting.", exitCode: 128)
        }

        if !quiet {
            try Self.printOutcome(outcome)
        } else if case .conflicts = outcome {
            try Self.printOutcome(outcome)
        }
    }

    /// Merge what's left of several heads once ``GitClient/mergeHeads(reducing:)``
    /// reduced them, as `git merge` does: nothing left is up to date, one
    /// is an ordinary merge, more an octopus merge, which can't
    /// fast-forward.
    static func merge(
        heads: MergeHeads, mode: FastForwardMode, message: String,
        client: SwiftGit.GitClient, quiet: Bool
    ) async throws {
        if heads.heads.isEmpty {
            if !quiet { Shell.print("Already up to date.") }
            return
        }
        if heads.heads.count == 1 {
            let outcome: MergeOutcome
            do {
                // git ends a message with a newline.
                outcome = try await client.merge(ref: heads.heads[0], fastForward: mode,
                                                 message: message + "\n", author: nil)
            } catch let err as Libgit2Error where err.message.contains("Not possible to fast-forward") {
                throw try await Pull.notPossibleToFastForward(client: client)
            }
            if case .conflicts(let paths) = outcome {
                try await Pull.writeMergeMessage(message, conflicts: paths, client: client)
            }
            if !quiet {
                try printOutcome(outcome)
            } else if case .conflicts = outcome {
                try printOutcome(outcome)
            }
            return
        }
        if mode == .onlyFastForward { throw try await Pull.notPossibleToFastForward(client: client) }
        let result = try await client.octopusMerge(
            heads: heads.heads, noFastForward: mode == .never, message: message)
        try printOctopus(result, quiet: quiet)
    }

    /// What git's octopus strategy says, step by step, then how the
    /// merge ended: `git-merge-octopus` and `git-merge-one-file` write
    /// the steps to stdout and their errors to stderr, as they happen.
    static func printOctopus(_ result: OctopusMergeResult, quiet: Bool) throws {
        let stderr = Shell.current.stderr
        func error(_ line: String) { stderr.write(Data((line + "\n").utf8)) }
        for step in result.steps {
            switch step.kind {
            case .alreadyUpToDate: Shell.print("Already up to date with \(step.head)")
            case .fastForward: Shell.print("Fast-forwarding to: \(step.head)")
            case .merge: Shell.print("Trying simple merge with \(step.head)")
            }
            guard let automatic = step.automatic else { continue }
            Shell.print("Simple merge did not work, trying automatic merge.")
            for path in automatic {
                switch path {
                case .merged(let path):
                    Shell.print("Auto-merging \(path)")
                case .conflict(let path):
                    Shell.print("Auto-merging \(path)")
                    error("ERROR: content conflict in \(path)")
                case .addedInBoth(let path, let emptyBlobMissing):
                    Shell.print("Added \(path) in both, but differently.")
                    if emptyBlobMissing {
                        // git-merge-one-file reads an empty blob it never wrote.
                        error("fatal: unable to read blob object e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
                        error("error: Could not stat : No such file or directory")
                    }
                    error("ERROR: content conflict in \(path)")
                case .addedOverDirectory(let path, let files):
                    Shell.print("Adding \(path)")
                    for file in files {
                        error("error: '\(file)' appears as both a file and as a directory")
                        error("error: \(file): cannot add to the index - missing --add option?")
                        error("fatal: git update-index: --cacheinfo cannot add \(file)")
                    }
                case .symlink(let path):
                    error("ERROR: \(path): Not merging symbolic link changes.")
                case .submodule(let path):
                    error("ERROR: \(path): Not merging conflicting submodule changes.")
                case .removed:
                    break
                case .submoduleDirectoryKept(let path):
                    error("warning: unable to rmdir '\(path)': Directory not empty")
                case .addedOverUntracked(let path):
                    Shell.print("Adding \(path)")
                    error("ERROR: untracked \(path) is overwritten by the merge.")
                case .deletedWithModeChange(let path):
                    error("ERROR: File \(path) deleted on one branch but had its")
                    error("ERROR: permissions changed on the other.")
                case .permissionsConflict(let path, let base, let ours, let theirs, let contentConflict):
                    Shell.print("Auto-merging \(path)")
                    let content = contentConflict ? "content conflict, " : ""
                    error("ERROR: \(content)permissions conflict: \(base)->\(ours),\(theirs) in \(path)")
                case .addedWithDifferentModes(let path, let ours, let theirs):
                    error("ERROR: File \(path) added identically in both branches,")
                    error("ERROR: but permissions conflict \(ours)->\(theirs).")
                case .notHandled(let path, let base, let ours, let theirs):
                    error("ERROR: \(path): Not handling case \(base) -> \(ours) -> \(theirs)")
                }
            }
            if automatic.contains(where: \.failed) { error("fatal: merge program failed") }
        }

        let failed = "Merge with strategy octopus failed."
        switch result.outcome {
        case .mergeCommit(_, let summary, _, _, let lines):
            guard !quiet else { return }
            Shell.print("Merge made by the 'octopus' strategy.")
            Shell.print(summary)
            // Created, deleted, renamed, mode changed: git's summary.
            for line in lines { Shell.print(line) }
        case .conflicts:
            Shell.print("Automatic merge failed; fix conflicts and then commit the result.")
            throw CLIError.stderr([], exitCode: 1)
        case .headNotUpdated(let lockFile, let reason):
            // The merge is staged for `git commit`; HEAD couldn't move.
            // git says why, with a hint where another process holds it.
            if !quiet { Shell.print("Merge made by the 'octopus' strategy.") }
            let unable = "fatal: update_ref failed for ref 'HEAD': cannot lock ref 'HEAD': Unable to create '"
                + asSeen(lockFile) + "': " + reason
            let held = reason == "File exists"
            throw CLIError.stderr(held ? [unable + ".", "",
                "Another git process seems to be running in this repository, or the lock file may be stale"]
                : [unable], exitCode: 128)
        case .headMoved(let expected, let actual):
            // Something moved HEAD's ref meanwhile: git's update_ref
            // refuses, leaving the merge staged.
            if !quiet { Shell.print("Merge made by the 'octopus' strategy.") }
            throw CLIError.stderr(["fatal: update_ref failed for ref 'HEAD': cannot lock ref 'HEAD': is at "
                + actual + " but expected " + expected], exitCode: 128)
        case .failed(let failure):
            switch failure {
            case .localChanges(let paths):
                Shell.print("Error: Your local changes to the following files would be overwritten by merge")
                for path in paths { Shell.print("    \(path)") }
                throw CLIError.stderr(failed, exitCode: 2)
            case .notUpToDate(let path):
                throw CLIError.stderr(["error: Entry '\(path)' not uptodate. Cannot merge.", failed], exitCode: 2)
            case .untrackedWouldBeOverwritten(let path):
                throw CLIError.stderr(
                    ["error: Untracked working tree file '\(path)' would be overwritten by merge.", failed],
                    exitCode: 2)
            case .untrackedFilesInDirectory(let path):
                throw CLIError.stderr(["error: Updating '\(path)' would lose untracked files in it", failed],
                                      exitCode: 2)
            case .noCommonCommit(let head):
                Shell.print("Unable to find common commit with \(head)")
                throw CLIError.stderr(failed, exitCode: 2)
            case .conflictsBeforeLastHead:
                Shell.print("Automated merge did not work.")
                Shell.print("Should not be doing an octopus.")
                throw CLIError.stderr(failed, exitCode: 2)
            }
        }
    }

    /// `path`, which libgit2 gives with symbolic links resolved, as git
    /// spells it: below the working directory (or one of its parents) as
    /// that is spelled, `/var/…` rather than `/private/var/…`.
    static func asSeen(_ path: String) -> String {
        func resolved(_ path: String) -> String? {
            #if os(Android) || os(Windows)
            return path
            #else
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            return String(cString: real)
            #endif
        }
        // The working directory as git spells it: $PWD where it names
        // the same directory.
        var directory = CommandContext.currentDirectory.path
        if let pwd = Shell.env("PWD"), resolved(pwd) != nil, resolved(pwd) == resolved(directory) { directory = pwd }
        while directory.count > 1 {
            if let real = resolved(directory), path.hasPrefix(real + "/") {
                return directory + path.dropFirst(real.count)
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return path
    }

    static func printOutcome(_ outcome: MergeOutcome) throws {
        switch outcome {
        case .alreadyUpToDate:
            Shell.print("Already up to date.")

        case .fastForward(let oldSHA, let newSHA, let summary, let added, let deleted):
            // An unborn branch just takes the commit, without a word.
            if oldSHA.allSatisfy({ $0 == "0" }) { return }
            Shell.print("Updating \(String(oldSHA.prefix(7)))..\(String(newSHA.prefix(7)))")
            Shell.print("Fast-forward")
            Shell.print(summary)
            for line in modeLines(added, deleted) { Shell.print(line) }

        case .mergeCommit(_, let summary, let added, let deleted):
            // Modern git (≥ 2.34) defaults to the 'ort' strategy. We
            // print the same string so output matches what users see today.
            Shell.print("Merge made by the 'ort' strategy.")
            Shell.print(summary)
            for line in modeLines(added, deleted) { Shell.print(line) }

        case .conflicts(let paths):
            // All three line groups go to stderr — that's where real git
            // writes them, and it ensures they show up in insertion order
            // when piped (stdout is line-buffered, stderr isn't).
            var lines: [String] = []
            for path in paths { lines.append("Auto-merging \(path)") }
            for path in paths { lines.append("CONFLICT (content): Merge conflict in \(path)") }
            lines.append("Automatic merge failed; fix conflicts and then commit the result.")
            throw CLIError.stderr(lines, exitCode: 1)
        }
    }
}

extension Merge {

    /// ` create mode …` and ` delete mode …` lines in path order, as
    /// git's diffstat summary lists them: by the paths' bytes, a quoted
    /// path's as they are before quoting.
    static func modeLines(_ added: [String], _ deleted: [String]) -> [String] {
        func path(_ line: String) -> [UInt8] {
            let text = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).dropFirst(3).first
                .map(String.init) ?? line
            return unquoted(text)
        }
        return (added + deleted).sorted { path($0).lexicographicallyPrecedes(path($1)) }
    }

    /// The bytes of a path git quoted (quote_c_style), or of one it
    /// didn't.
    static func unquoted(_ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        guard bytes.count >= 2, bytes.first == 0x22, bytes.last == 0x22 else { return bytes }
        let escapes: [UInt8: UInt8] = [0x61: 7, 0x62: 8, 0x74: 9, 0x6E: 10, 0x76: 11, 0x66: 12, 0x72: 13]
        var out: [UInt8] = []
        var cursor = 1
        while cursor < bytes.count - 1 {
            let byte = bytes[cursor]
            guard byte == 0x5C, cursor + 1 < bytes.count - 1 else { out.append(byte); cursor += 1; continue }
            let next = bytes[cursor + 1]
            if (0x30...0x37).contains(next), cursor + 3 < bytes.count {
                out.append(bytes[(cursor + 1)...(cursor + 3)].reduce(0) { $0 &* 8 &+ ($1 &- 0x30) })
                cursor += 4
            } else {
                out.append(escapes[next] ?? next)
                cursor += 2
            }
        }
        return out
    }
}
