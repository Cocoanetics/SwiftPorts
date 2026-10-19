#if os(macOS) || os(Linux)
import CLibgit2Shim
import Foundation
import GitKit
import Testing
@testable import SwiftGit

@Suite("where the system config lives", .serialized)
struct GitClientSystemConfigPathTests {

    /// The path comes from libgit2's search path for the system level,
    /// not a fixed `/etc`; a disabled level (`GIT_CONFIG_NOSYSTEM`) gives
    /// the usual place, as git still names it.
    @Test func followsLibgit2sSearchPath() throws {
        Libgit2.ensureInitialized()
        // Under the sandbox lock, so no other git operation sees the change.
        try Libgit2Sandboxing.shared.runIsolated(nil) {
            #expect(swiftports_libgit2_set_search_path(2, "/opt/etcish") == 0)
            #expect(GitClient.systemConfigPath() == "/opt/etcish/gitconfig")
            #expect(swiftports_libgit2_set_search_path(2, "") == 0)
            #expect(GitClient.systemConfigPath() == "/etc/gitconfig")
            #expect(swiftports_libgit2_set_search_path(2, nil) == 0)
        }
    }

    /// Without a sandbox the process's XDG_CONFIG_HOME names the XDG config
    /// directory, as it does for git.
    @Test func processXDGConfigHome() throws {
        let saved = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        defer {
            if let saved { setenv("XDG_CONFIG_HOME", saved, 1) } else { unsetenv("XDG_CONFIG_HOME") }
        }
        let savedHome = ProcessInfo.processInfo.environment["HOME"]
        defer { if let savedHome { setenv("HOME", savedHome, 1) } }
        setenv("HOME", "/custom/home", 1)
        #expect(Libgit2Sandboxing.shared.home(for: nil) == "/custom/home")
        setenv("XDG_CONFIG_HOME", "/custom/xdg", 1)
        #expect(Libgit2Sandboxing.shared.xdgConfigHome(for: nil) == "/custom/xdg")
        unsetenv("XDG_CONFIG_HOME")
        #expect(Libgit2Sandboxing.shared.xdgConfigHome(for: nil) == "/custom/home/.config")
    }

    /// An include's path is a config value: quotes group, a backslash
    /// escapes, an unquoted `#` or `;` starts a comment.
    @Test func configValuesAreReadLikeGit() {
        #expect(GitClient.configValue(#"  "a b" # note"#) == "a b")
        #expect(GitClient.configValue(#"a\tb ; note"#) == "a\tb")
        #expect(GitClient.configValue(#""keep  " trailing  "#) == "keep   trailing")
        #expect(GitClient.configValue("plain") == "plain")
    }

    /// The search path is a list: the file may be in a later directory.
    @Test func searchesEveryDirectory() throws {
        Libgit2.ensureInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemConfigPath-\(UUID().uuidString)")
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "[a]\n\tb = c\n".write(
            to: second.appendingPathComponent("gitconfig"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = second.resolvingSymlinksInPath().path
        try Libgit2Sandboxing.shared.runIsolated(nil) {
            #expect(swiftports_libgit2_set_search_path(2, "\(first.path):\(second.path)") == 0)
            let found = GitClient.systemConfigPath()
            #expect(URL(fileURLWithPath: found).resolvingSymlinksInPath().path == canonical + "/gitconfig")
            #expect(swiftports_libgit2_set_search_path(2, nil) == 0)
        }
    }
}
#endif
