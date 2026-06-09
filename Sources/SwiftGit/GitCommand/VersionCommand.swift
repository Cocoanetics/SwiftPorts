import ArgumentParser
import ShellKit
import libgit2

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show client and libgit2 versions."
    )

    func run() throws {
        var major: Int32 = 0, minor: Int32 = 0, patch: Int32 = 0
        git_libgit2_version(&major, &minor, &patch)
        Shell.print("git (SwiftPorts) 0.1.0-dev")
        Shell.print("libgit2 \(major).\(minor).\(patch)")
    }
}
