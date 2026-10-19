#if os(macOS) || os(Linux)
import CLibgit2Shim
import Foundation
import GitKit
import Testing
@testable import SwiftGit

@Suite("where the system config lives")
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
}
#endif
