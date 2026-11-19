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

    /// A short random name, so paths under the root (worktree metadata
    /// included) stay within Windows' `MAX_PATH`, which libgit2 enforces there.
    static func shortName(_ prefix: String) -> String {
        // Callers also pass descriptive endpoint-table labels, including URLs.
        // Keep those labels from introducing Windows-invalid path characters.
        let safePrefix = prefix.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression).prefix(24)
        return "\(safePrefix)-\(UUID().uuidString.prefix(8))"
    }

    /// Makes the directories and an empty global config under a fresh
    /// temporary root.
    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.shortName("LFS"), isDirectory: true)
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

    /// The same regions as ``sandbox``, refusing URLs for which `refuses` is true.
    func sandbox(refusing refuses: @escaping @Sendable (URL) -> Bool) -> Sandbox {
        let open = sandbox
        return Sandbox(
            documentsDirectory: open.documentsDirectory,
            downloadsDirectory: open.downloadsDirectory,
            libraryDirectory: open.libraryDirectory,
            moviesDirectory: open.moviesDirectory,
            musicDirectory: open.musicDirectory,
            picturesDirectory: open.picturesDirectory,
            sharedPublicDirectory: open.sharedPublicDirectory,
            temporaryDirectory: open.temporaryDirectory,
            trashDirectory: open.trashDirectory,
            userDirectory: open.userDirectory,
            cachesDirectory: open.cachesDirectory,
            homeDirectory: open.homeDirectory,
            authorize: { url in
                if refuses(url) {
                    throw Sandbox.Denial(url: url, reason: "denied")
                }
            })
    }

    /// Runs `body` in a shell whose git configuration is this host's.
    func run<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        let shell = Shell(environment: Environment(variables: variables, workingDirectory: root.path))
        shell.sandbox = sandbox
        return try await shell.withCurrent(body)
    }
}
