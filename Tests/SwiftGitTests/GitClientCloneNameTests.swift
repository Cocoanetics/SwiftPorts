import Testing
@testable import SwiftGit

/// The directory `git clone` guesses for a remote (`git_url_basename`),
/// checked against git 2.54.
@Suite struct GitClientCloneNameTests {

    @Test func namesFollowGit() {
        let cases: [(remote: String, name: String?)] = [
            ("git@host:org/repo.git/", "repo"),
            ("https://user:token@host/org/repo.git", "repo"),
            // Only a host: its name, without credentials or port.
            ("https://user@host", "host"),
            ("ssh://host:2222/", "host"),
            // A port-like last component of a path stays.
            ("host:/foo/bar:2222.git", "2222"),
            ("host:bar.git", "bar"),
            ("host:srv/repo/.git", "repo"),
            ("host:srv/my\tproject  x .git", "my project x"),
            ("file:///srv/a b/", "a b"),
            ("host:.git", nil),
            (":", nil),
        ]
        for testCase in cases {
            #expect(GitClient.humanishName(of: testCase.remote) == testCase.name, "\(testCase.remote)")
        }
    }

    @Test func backslashesSeparateOnlyOnWindows() {
        #if os(Windows)
        #expect(GitClient.humanishName(of: #"C:\repos\project.git"#) == "project")
        #expect(GitClient.humanishName(of: #"\\server\share\project\"#) == "project")
        #else
        #expect(GitClient.humanishName(of: #"C:\repos\project.git"#) == #"\repos\project"#)
        #endif
    }

    /// Which `<repository>` paths are joined to the top of the work tree.
    @Test func relativePathsFollowGit() {
        #expect(GitClient.isRelativePath("../bare"))
        #expect(GitClient.isRelativePath("bare.git"))
        #expect(!GitClient.isRelativePath("/srv/bare.git"))
        #if os(Windows)
        #expect(!GitClient.isRelativePath(#"\\server\share\bare.git"#))
        #expect(!GitClient.isRelativePath(#"\bare.git"#))
        #expect(!GitClient.isRelativePath(#"C:\bare.git"#))
        #expect(!GitClient.isRelativePath("C:/bare.git"))
        #expect(GitClient.isRelativePath(#"..\bare"#))
        #else
        #expect(GitClient.isRelativePath(#"\bare.git"#))
        #endif
    }
}
