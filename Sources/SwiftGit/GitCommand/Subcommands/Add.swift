import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Stage paths into the index.",
        discussion: """
            Behaviour mirrors `git add`:
            - With no paths and no `-A`: error (matches `git add` with no args).
            - With explicit pathspecs: each must exist and not be ignored
              (use `-f`/`--force` to override the ignore check).
            - With `-A`: stage every change in the working tree, silently
              skipping ignored files.
            On success the command is silent (matches real git).
            """
    )

    @Flag(name: [.customShort("A"), .customLong("all")],
          help: "Stage every change in the working tree.")
    var all: Bool = false

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Allow adding otherwise ignored files.")
    var force: Bool = false

    @Argument(help: "Pathspecs to stage. Mutually exclusive with -A.",
              completion: .file())
    var paths: [String] = []

    func validate() throws {
        if !all && paths.isEmpty {
            throw ValidationError("Nothing specified, nothing added.")
        }
        if all && !paths.isEmpty {
            throw ValidationError("-A is incompatible with explicit pathspecs")
        }
    }

    func run() async throws {
        do { try await stage() }
        catch let error as GitFilterError { throw CLIError(filter: error) }
    }

    private func stage() async throws {
        let client = CommandContext.gitClient()

        if all {
            // `-A` always uses libgit2's all-paths mode, which silently
            // skips ignored files — same as real `git add -A`.
            try await client.add(paths: [])
            return
        }

        // Explicit pathspecs: validate each before staging so we can
        // emit the same errors real git does.
        let cwd = CommandContext.currentDirectory
        var ignored: [String] = []
        for path in paths {
            let resolvedURL = URL(fileURLWithPath: path, relativeTo: cwd)
            // Gate the user-supplied pathspec through the active
            // sandbox. A denied path is reported the same as a missing
            // one — real git says `did not match any files` in both
            // shapes, and the sandbox-leak protection in
            // `Sandbox.Denial.description` keeps the host path out of
            // the diagnostic.
            do {
                try await Shell.authorize(resolvedURL)
            } catch is Sandbox.Denial {
                throw CLIError.stderr(
                    "fatal: pathspec '\(path)' did not match any files",
                    exitCode: 128)
            }
            if !FileManager.default.fileExists(atPath: resolvedURL.path) {
                throw CLIError.stderr(
                    "fatal: pathspec '\(path)' did not match any files",
                    exitCode: 128)
            }
            if !force, (try? await client.isIgnored(path)) == true {
                ignored.append(path)
            }
        }

        if !ignored.isEmpty {
            var lines = ["The following paths are ignored by one of your .gitignore files:"]
            lines.append(contentsOf: ignored)
            lines.append("hint: Use -f if you really want to add them.")
            lines.append(#"hint: Disable this message with "git config set advice.addIgnoredFile false""#)
            throw CLIError.stderr(lines, exitCode: 1)
        }

        try await client.add(paths: paths)
    }
}
