// A per-test stand-in for the host's git configuration, as
// `IsolatedGitHost` is for the git suites: the embedded client reads config
// through its Shell's environment and libgit2's option block, the oracle's
// system `git` through its process environment, and both are pointed at
// disposable directories here, so a developer's own `lfs.storage` (or any
// other global/system setting) can't reach a test or its store.
import Foundation
import ShellKit

struct IsolatedLFSHost: Sendable {
    let root: URL
    let home: URL
    let xdgConfigHome: URL
    let globalConfig: URL

    /// Makes the directories and an empty global config under a fresh
    /// temporary root.
    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LFSHost-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        // libgit2 finds the global config as `$HOME/.gitconfig`; git is told the same file.
        globalConfig = home.appendingPathComponent(".gitconfig")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: xdgConfigHome, withIntermediateDirectories: true)
        try? "".write(to: globalConfig, atomically: true, encoding: .utf8)
    }

    /// The variables that isolate git's configuration.
    var variables: [String: String] {
        ["HOME": home.path,
         "XDG_CONFIG_HOME": xdgConfigHome.path,
         "GIT_CONFIG_GLOBAL": globalConfig.path,
         "GIT_CONFIG_NOSYSTEM": "1"]
    }

    /// A sandbox that allows everything, but so libgit2 is pointed at the
    /// shell's `HOME` / `XDG_CONFIG_HOME` — `Libgit2Sandboxing` applies them
    /// only when the shell has one.
    var sandbox: Sandbox {
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        return Sandbox(
            documentsDirectory: tmp, downloadsDirectory: tmp, libraryDirectory: tmp,
            moviesDirectory: tmp, musicDirectory: tmp, picturesDirectory: tmp,
            sharedPublicDirectory: tmp, temporaryDirectory: tmp, trashDirectory: tmp,
            userDirectory: tmp, cachesDirectory: tmp, homeDirectory: home,
            authorize: { _ in })
    }

    /// Runs `body` in a shell whose git configuration is this host's.
    func run<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        let shell = Shell(environment: Environment(variables: variables, workingDirectory: root.path))
        shell.sandbox = sandbox
        return try await shell.withCurrent(body)
    }
}
