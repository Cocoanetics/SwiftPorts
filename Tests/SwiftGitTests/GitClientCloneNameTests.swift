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

    /// Which remotes are scp-style `host:path` (`url_is_local_not_ssh`).
    @Test func scpStyleFollowsGit() {
        #expect(GitClient.isSCPLike("git@host:repo.git"))
        #expect(!GitClient.isSCPLike("/srv/team@host/repo:copy.git"))
        #expect(!GitClient.isSCPLike("ssh://host/repo.git"))
        #if os(Windows)
        // git 2.54's drive prefix is any one character and a colon.
        #expect(!GitClient.isSCPLike("C:/repo.git"))
        #expect(!GitClient.isSCPLike(#"c:\repo.git"#))
        #expect(!GitClient.isSCPLike("1:repo.git"))
        #expect(!GitClient.isSCPLike("ä:repo.git"))
        // A drive path, even with `//` after the colon.
        #expect(!GitClient.isURLOrSCPLike("C://repos/repo.git"))
        #else
        #expect(GitClient.isSCPLike("C:/repo.git"))
        #expect(GitClient.isSCPLike("1:repo.git"))
        #expect(GitClient.isURLOrSCPLike("C://repos/repo.git"))
        #endif
        #expect(GitClient.isURLOrSCPLike("https://host/repo.git"))
        #expect(!GitClient.isURLOrSCPLike("../repo.git"))
    }

    /// git's URL syntax (`is_url`), and the schemes it has a transport for.
    @Test func urlSchemesFollowGit() throws {
        #expect(GitClient.urlScheme(of: "https://host/r.git") == "https")
        #expect(GitClient.urlScheme(of: "git+ssh://host/r.git") == "git+ssh")
        #expect(GitClient.urlScheme(of: "C://repos/r.git") == "C")
        #expect(GitClient.urlScheme(of: "git@host:r.git") == nil)
        #expect(GitClient.urlScheme(of: "me@host:path://x") == nil)
        #expect(GitClient.urlScheme(of: "+x://host/r") == nil)
        try GitClient.requireTransport(for: "ssh://host/r.git")
        try GitClient.requireTransport(for: "git@host:r.git")
        #expect(throws: UnsupportedTransportError.noHelper(scheme: "foo")) {
            try GitClient.requireTransport(for: "foo://host/r.git")
        }
        // `://` after anything but a scheme: git knows no such protocol.
        for (remote, name) in [("a_://host/r", "a_"), ("+x://host/r", "+x"),
                               ("foo/bar://host/r", "foo/bar"), ("me@host:path://x", "me@host:path")] {
            #expect(throws: UnsupportedTransportError.protocolNotSupported(name)) {
                try GitClient.requireTransport(for: remote)
            }
        }
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
