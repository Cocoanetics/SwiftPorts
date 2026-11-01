// A per-test stand-in for the host's git configuration (#143). The embedded
// client reads config through its Shell's environment and libgit2's option
// block, and the system `git` through its process environment; both are
// pointed at disposable directories here, so a developer's own
// `pull.rebase` (or any other global/system setting) can't reach a test.
#if os(macOS) || os(Linux)
import Foundation
import ShellKit

struct IsolatedGitHost: Sendable {
    let home: URL
    let xdgConfigHome: URL
    let globalConfig: URL

    /// Makes the directories and an empty (or `config`-filled) global
    /// config under a fresh temporary root.
    init(globalConfig config: String = "") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHost-\(UUID().uuidString)")
        home = root.appendingPathComponent("home", isDirectory: true)
        xdgConfigHome = root.appendingPathComponent("xdg", isDirectory: true)
        // libgit2 finds the global config as `$HOME/.gitconfig`; git is told the same file.
        globalConfig = home.appendingPathComponent(".gitconfig")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: xdgConfigHome, withIntermediateDirectories: true)
        try? config.write(to: globalConfig, atomically: true, encoding: .utf8)
    }

    /// The variables that isolate git's configuration.
    var variables: [String: String] {
        ["HOME": home.path,
         "XDG_CONFIG_HOME": xdgConfigHome.path,
         "GIT_CONFIG_GLOBAL": globalConfig.path,
         "GIT_CONFIG_NOSYSTEM": "1"]
    }

    /// An embedded shell's environment: `extra` over the isolating variables.
    func environment(_ extra: [String: String] = [:], workingDirectory: String) -> Environment {
        Environment(variables: variables.merging(extra) { _, new in new }, workingDirectory: workingDirectory)
    }

    /// A sandbox that allows everything, but so libgit2 is pointed at the
    /// shell's `HOME` / `XDG_CONFIG_HOME` — `Libgit2Sandboxing` applies them
    /// only when the shell has one.
    var sandbox: Sandbox {
        let tmp = home.deletingLastPathComponent().appendingPathComponent("tmp", isDirectory: true)
        return Sandbox(
            documentsDirectory: tmp, downloadsDirectory: tmp, libraryDirectory: tmp,
            moviesDirectory: tmp, musicDirectory: tmp, picturesDirectory: tmp,
            sharedPublicDirectory: tmp, temporaryDirectory: tmp, trashDirectory: tmp,
            userDirectory: tmp, cachesDirectory: tmp, homeDirectory: home,
            authorize: { _ in })
    }

    /// Gives a system-`git` subprocess the isolating variables over the
    /// test process's own.
    func isolate(_ process: Process) {
        process.environment = ProcessInfo.processInfo.environment.merging(variables) { _, new in new }
    }
}
#endif
