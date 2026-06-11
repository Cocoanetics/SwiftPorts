import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

struct RevParse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rev-parse",
        abstract: "Pick out and massage parameters."
    )

    @Flag(name: .customLong("short"),
          help: "Print abbreviated 7-char SHAs instead of full 40-char.")
    var short: Bool = false

    @Flag(name: .customLong("abbrev-ref"),
          help: "Print the symbolic shorthand of a ref (e.g. `main`).")
    var abbrevRef: Bool = false

    @Flag(name: .customLong("is-inside-work-tree"),
          help: "Print `true` / `false` and exit.")
    var isInsideWorkTree: Bool = false

    @Flag(name: .customLong("git-dir"),
          help: "Print the path to the .git directory.")
    var gitDir: Bool = false

    @Flag(name: .customLong("show-toplevel"),
          help: "Print the working-tree root.")
    var showToplevel: Bool = false

    @Argument(help: "Revisions to resolve.")
    var specs: [String] = []

    func run() async throws {
        let client = CommandContext.gitClient()
        let stdout = Shell.current.stdout

        if isInsideWorkTree {
            let inside = (try? await client.isInsideWorkTree()) ?? false
            stdout.write(Data("\(inside)\n".utf8))
            return
        }

        if gitDir {
            // Real git prints `.git` (relative) when cwd is the repo
            // root; libgit2 always returns an absolute trailing-slashed
            // path. Match real-git: trim trailing slash; if the path
            // resolves to `<cwd>/.git`, print the relative form.
            let path = (try? await client.gitDir()) ?? ""
            stdout.write(Data("\(formatGitDir(path))\n".utf8))
            return
        }

        if showToplevel {
            let path = (try? await client.toplevel()) ?? ""
            // libgit2 trailing-slashes the workdir; real git doesn't.
            let trimmed = path.hasSuffix("/") && path.count > 1
                ? String(path.dropLast())
                : path
            // libgit2 reports the HOST path; fold it back to the
            // script-visible spelling under a path-mapped sandbox
            // (a no-op otherwise).
            stdout.write(Data("\(Shell.displayPath(for: trimmed))\n".utf8))
            return
        }

        // Default: resolve each spec to a SHA (or shorthand with --abbrev-ref).
        for spec in specs {
            if abbrevRef {
                if let branch = try? await client.currentBranch(),
                   spec == "HEAD" || spec == "@" {
                    stdout.write(Data("\(branch)\n".utf8))
                } else {
                    stdout.write(Data("\(spec)\n".utf8))
                }
                continue
            }
            do {
                let sha = try await client.resolveOID(spec)
                let toPrint = short ? String(sha.prefix(7)) : sha
                stdout.write(Data("\(toPrint)\n".utf8))
            } catch {
                throw CLIError.stderr(
                    "fatal: ambiguous argument '\(spec)': unknown revision or path not in the working tree.",
                    exitCode: 128)
            }
        }
    }

    /// Match real-git's `.git` shorthand when the working dir is the
    /// repo root, fall back to the absolute path otherwise.
    private func formatGitDir(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1
            ? String(path.dropLast())
            : path
        let cwd = Shell.currentDirectory.path
        if trimmed == "\(cwd)/.git" { return ".git" }
        // Absolute fallback: libgit2 reports the HOST path; fold it
        // back to the script-visible spelling under a path-mapped
        // sandbox (a no-op otherwise).
        return Shell.displayPath(for: trimmed)
    }
}
