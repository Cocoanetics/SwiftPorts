#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("LFS env raw same-path oracle", .enabled(if: LFSOracle.isAvailable))
struct LFSEnvOracleTests {
    @Test func remotesAndPaths() throws {
        let fixture = try LFSEnvOracleFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.repository("env")
        try fixture.compare(repo)
        try fixture.system(["remote", "add", "origin", "https://example.com/o.git"], cwd: repo)
        try fixture.compare(repo)
        try fixture.system(["remote", "add", "other", "https://example.com/u.git"], cwd: repo)
        // origin is emitted first; only one remote remains in upstream's Go map.
        try fixture.compare(repo)
        try fixture.config("user.name", "Oracle", cwd: repo)
        try fixture.config("user.email", "oracle@example.com", cwd: repo)
        try fixture.system(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "init"], cwd: repo)
        try fixture.config("branch.main.remote", "origin", cwd: repo)
        try fixture.config("branch.main.pushremote", "other", cwd: repo)
        try fixture.config("lfs.https://example.com/o.git/info/lfs.access", "private", cwd: repo)
        try fixture.config("lfs.https://example.com/u.git/info/lfs.access", "negotiate", cwd: repo)
        try fixture.compare(repo)
        let linked = fixture.host.root.appendingPathComponent("linked")
        try fixture.system(["worktree", "add", "-qb", "linked", linked.path], cwd: repo)
        try fixture.compare(linked)
        let subdirectory = repo.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try fixture.compare(subdirectory)
        try fixture.compare(repo.appendingPathComponent(".git"))
        for storage in ["../media", fixture.host.root.appendingPathComponent("absolute-store").path,
                        fixture.host.root.path + "/unused/../absolute-store/"] {
            try fixture.config("lfs.storage", storage, cwd: repo)
            try fixture.compare(repo)
        }
        try fixture.config("lfs.url", "https://example.com/override", cwd: repo)
        try fixture.compare(repo)
        let bare = try fixture.repository("bare", bare: true)
        try fixture.compare(bare)
        try fixture.compare(fixture.host.home)
        try fixture.system(["config", "--global", "lfs.storage", "outside-store"], cwd: fixture.host.home)
        try fixture.compare(fixture.host.home)
    }

    @Test func sshAndFilters() throws {
        let fixture = try LFSEnvOracleFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.repository("ssh")
        for remote in ["git@example.com:team/repo.git", "ssh://alice@example.com:2222/team/repo.git"] {
            try fixture.config("remote.origin.url", remote, cwd: repo)
            try fixture.compare(repo)
        }
        for key in ["filter.lfs.process", "filter.lfs.smudge", "filter.lfs.clean"] {
            try fixture.config(key, "command \"quoted\" \\path\ttab\nnewline", cwd: repo)
        }
        try fixture.compare(repo)
        // Original environment strings are printed even when they contain ./.
        try fixture.compare(repo, extra: ["GIT_DIR=./.git", "GIT_WORK_TREE=."])
    }

    @Test func configurationAndWarnings() throws {
        let fixture = try LFSEnvOracleFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.repository("settings")
        let settings = [
            ("lfs.concurrenttransfers", "+12"), ("lfs.tustransfers", "yes"),
            ("lfs.skipdownloaderrors", "true"), ("lfs.fetchrecentalways", "on"),
            ("lfs.fetchrecentrefsdays", "-2"), ("lfs.fetchrecentcommitsdays", "3"),
            ("lfs.fetchrecentremoterefs", "false"), ("lfs.pruneoffsetdays", "4"),
            ("lfs.pruneverifyremotealways", "true"), ("lfs.pruneverifyunreachablealways", "true"),
            ("lfs.pruneremotetocheck", "upstream"), ("lfs.fetchinclude", " foo/, bar\\, ,baz// "),
            ("lfs.fetchexclude", " cache/, *.tmp "), ("lfs.extension.zip.priority", "5"),
            ("lfs.customtransfer.zed.path", "unused"), ("lfs.customtransfer.zed.direction", "upload"),
            ("lfs.customtransfer.alpha.path", "unused"), ("lfs.customtransfer.alpha.direction", "download"),
            ("lfs.customtransfer.both.path", "unused"), ("lfs.customtransfer.bad.path", "unused"),
            ("lfs.customtransfer.bad.direction", "invalid")
        ]
        for (key, value) in settings { try fixture.config(key, value, cwd: repo) }
        try fixture.compare(repo, extra: ["GIT_LFS_SKIP_DOWNLOAD_ERRORS=false"])
        try fixture.config("lfs.skipdownloaderrors", "false", cwd: repo)
        try fixture.compare(repo, extra: ["GIT_LFS_SKIP_DOWNLOAD_ERRORS=yes"])
        try fixture.config("lfs.basictransfersonly", "true", cwd: repo)
        try fixture.compare(repo)
        try fixture.config("lfs.concurrenttransfers", "9k", cwd: repo)
        try fixture.config("lfs.fetchrecentrefsdays", " 9", cwd: repo)
        try fixture.compare(repo)
        let safe = "[lfs]\n fetchinclude = from-file/\n concurrenttransfers = 99\n"
        try Data(safe.utf8).write(to: repo.appendingPathComponent(".lfsconfig"))
        try fixture.compare(repo)
        try fixture.system(["config", "--add", "lfs.concurrenttransfers", "3"], cwd: repo)
        try fixture.compare(repo)
    }

    @Test func alternateReferences() throws {
        let fixture = try LFSEnvOracleFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.repository("alternates")
        let reference = try fixture.repository("reference", bare: true)
        try FileManager.default.createDirectory(
            at: reference.appendingPathComponent("lfs/objects"), withIntermediateDirectories: true)
        let relative = repo.appendingPathComponent("relative")
        try FileManager.default.createDirectory(at: relative.appendingPathComponent("objects"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relative.appendingPathComponent("lfs/objects"),
                                                withIntermediateDirectories: true)
        let alternates = "\n# comment\n\(reference.path)/objects\nrelative/objects\n/missing/objects\n"
        try Data(alternates.utf8).write(to: repo.appendingPathComponent(".git/objects/info/alternates"))
        try fixture.compare(repo, extra: ["GIT_ALTERNATE_OBJECT_DIRECTORIES=" + reference.path + "/objects"])
    }
}
#endif
