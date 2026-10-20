// The files `git config --global` / `--system` work on: the ones the
// environment names, permission failures, and the sandbox gate.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git config files named by the environment")
struct GitCommandConfigFileTests: ConfigTestHelpers {

    @Test("a --system write that can't create the file fails as git's does")
    func systemWriteWithoutPermission() async throws {
        // Only where /etc/gitconfig can't be started: never create it.
        guard !FileManager.default.fileExists(atPath: "/etc/gitconfig"),
              !FileManager.default.isWritableFile(atPath: "/etc") else { return }
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        // No sandbox: with one, the host's /etc is outside its root and refused.
        let result = try await git(["config", "--system", "a.b", "c"], root: root, home: home, work: work,
                                   sandboxed: false)
        #expect(result.stderr == "error: could not lock config file /etc/gitconfig: Permission denied\n")
        #expect(result.status == 255)

        // An explicit --system ignores GIT_CONFIG_NOSYSTEM, which the
        // helper sets: listing the missing file is still git's error.
        let list = try await git(["config", "--system", "--list"], root: root, home: home, work: work)
        #expect(list.stderr == "fatal: unable to read config file '/etc/gitconfig': No such file or directory\n")
        #expect(list.status == 128)
        let get = try await git(["config", "--system", "--get", "a.b"], root: root, home: home, work: work)
        #expect(get.status == 1)
    }

    @Test("a sandbox refuses to change the host's system config")
    func systemWriteIsAuthorized() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["a.b", "c"], ["--unset", "a.b"]] {
            await #expect(throws: Sandbox.Denial.self) {
                try await self.git(["config", "--system"] + args, root: root, home: home, work: work)
            }
        }
    }

    @Test("--global works on ~/.gitconfig if there is one, else the XDG file")
    func globalFileSelection() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgDirectory = home.appendingPathComponent(".config/git")
        try FileManager.default.createDirectory(at: xdgDirectory, withIntermediateDirectories: true)
        let xdg = xdgDirectory.appendingPathComponent("config")
        try "[a]\n\tb = xdg\n".write(to: xdg, atomically: true, encoding: .utf8)
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work)
        }

        // Only the XDG file: read from it, written to it.
        #expect(try await run(["--get", "a.b"]).stdout == "xdg\n")
        #expect(try await run(["x.y", "z"]).status == 0)
        #expect(try String(contentsOf: xdg, encoding: .utf8) == "[a]\n\tb = xdg\n[x]\n\ty = z\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".gitconfig").path))

        // With ~/.gitconfig too, the XDG file is left out.
        try "[h]\n\tz = home\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        #expect(try await run(["--get", "a.b"]).status == 1)
        #expect(try await run(["--list"]).stdout == "h.z=home\n")

        // A lock failure names the file that was picked.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".gitconfig"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: xdgDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xdgDirectory.path) }
        if getuid() != 0 {
            let locked = try await run(["q.r", "s"])
            #expect(locked.stderr == "error: could not lock config file \(xdg.path): Permission denied\n")
            #expect(locked.status == 255)
        }
    }

    @Test("GIT_CONFIG_SYSTEM names the system file, which is read even under GIT_CONFIG_NOSYSTEM")
    func systemFileFromTheEnvironment() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("system.cfg")
        let environment = ["GIT_CONFIG_SYSTEM": system.path]
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config"] + args, root: root, home: home, work: work, environment: environment)
        }

        // Missing: git's error names the file, and a get finds nothing.
        let missing = try await run(["--system", "--list"])
        #expect(missing.stderr == "fatal: unable to read config file '\(system.path)': No such file or directory\n")
        #expect(missing.status == 128)
        #expect(try await run(["--system", "--get", "a.b"]).status == 1)

        // A write starts it, and every read of it works despite NOSYSTEM.
        #expect(try await run(["--system", "a.b", "c"]).status == 0)
        #expect(try String(contentsOf: system, encoding: .utf8) == "[a]\n\tb = c\n")
        #expect(try await run(["--system", "--list"]).stdout == "a.b=c\n")
        #expect(try await run(["--system", "--get", "a.b"]).stdout == "c\n")
        #expect(try await run(["--system", "--unset", "a.b"]).status == 0)
        #expect(try await run(["--system", "--get", "a.b"]).status == 1)
    }

    @Test("GIT_CONFIG_GLOBAL names the global file")
    func globalFileFromTheEnvironment() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[h]\n\tx = home\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let chosen = root.appendingPathComponent("chosen.cfg")
        try "[o]\n\ty = override\n".write(to: chosen, atomically: true, encoding: .utf8)
        func run(_ args: [String], _ file: URL = chosen) async throws -> ConfigOutput {
            try await git(["config"] + args, root: root, home: home, work: work,
                          environment: ["GIT_CONFIG_GLOBAL": file.path])
        }

        #expect(try await run(["--global", "--list"]).stdout == "o.y=override\n")
        #expect(try await run(["--global", "--get", "o.y"]).stdout == "override\n")
        #expect(try await run(["--global", "--get", "h.x"]).status == 1)

        // A write goes to that file, not to ~/.gitconfig.
        let other = root.appendingPathComponent("new.cfg")
        #expect(try await run(["--global", "a.b", "c"], other).status == 0)
        #expect(try String(contentsOf: other, encoding: .utf8) == "[a]\n\tb = c\n")
        #expect(try String(contentsOf: home.appendingPathComponent(".gitconfig"), encoding: .utf8)
                == "[h]\n\tx = home\n")

        // A named file that isn't there is the error of git's.
        let none = root.appendingPathComponent("none.cfg")
        let missing = try await run(["--global", "--list"], none)
        #expect(missing.stderr == "fatal: unable to read config file '\(none.path)': No such file or directory\n")
        #expect(missing.status == 128)
    }

    @Test("a relative GIT_CONFIG_GLOBAL is the working directory's, and printed as typed")
    func relativeConfigFileName() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ args: [String], _ name: String = "rel.cfg") async throws -> ConfigOutput {
            try await git(["config"] + args, root: root, home: home, work: work,
                          environment: ["GIT_CONFIG_GLOBAL": name])
        }

        let missing = try await run(["--global", "--list"], "none.cfg")
        #expect(missing.stderr == "fatal: unable to read config file 'none.cfg': No such file or directory\n")
        #expect(try await run(["--global", "a.b", "c"]).status == 0)
        // Started in the working directory, not wherever the process is.
        #expect(try String(contentsOf: work.appendingPathComponent("rel.cfg"), encoding: .utf8)
                == "[a]\n\tb = c\n")
        #expect(try await run(["--global", "--get", "a.b"]).stdout == "c\n")
    }

    @Test("a config file the environment names must be inside the sandbox")
    func environmentFileIsAuthorized() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-escape-\(UUID().uuidString).cfg")
        try "[a]\n\tb = secret\n".write(to: outside, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        for args in [["--global", "--get", "a.b"], ["--global", "--list"], ["--global", "a.b", "x"],
                     ["--global", "--unset", "a.b"]] {
            await #expect(throws: Sandbox.Denial.self) {
                try await self.git(["config"] + args, root: root, home: home, work: work,
                                   environment: ["GIT_CONFIG_GLOBAL": outside.path])
            }
        }
        // Untouched.
        #expect(try String(contentsOf: outside, encoding: .utf8) == "[a]\n\tb = secret\n")
    }

    @Test("permission failures are git's: unreadable files, unwritable directories")
    func permissionFailures() async throws {
        // Root ignores file modes.
        guard getuid() != 0 else { return }
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path + "/locked")
            try? FileManager.default.removeItem(at: root)
        }
        let unreadable = root.appendingPathComponent("unreadable.cfg")
        try "[a]\n\tb = c\n".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        let list = try await git(["config", "--system", "--list"], root: root, home: home, work: work,
                                 environment: ["GIT_CONFIG_SYSTEM": unreadable.path])
        #expect(list.stderr == "fatal: unable to access '\(unreadable.path)': Permission denied\n")
        #expect(list.status == 128)

        // A get warns and finds nothing.
        let get = try await git(["config", "--system", "--get", "a.b"], root: root, home: home, work: work,
                                environment: ["GIT_CONFIG_SYSTEM": unreadable.path])
        #expect(get.stderr == "warning: unable to access '\(unreadable.path)': Permission denied\n")
        #expect(get.status == 1)

        let target = locked.appendingPathComponent("new.cfg")
        for scope in ["--global", "--system"] {
            let variable = scope == "--global" ? "GIT_CONFIG_GLOBAL" : "GIT_CONFIG_SYSTEM"
            let write = try await git(["config", scope, "x.y", "z"], root: root, home: home, work: work,
                                      environment: [variable: target.path])
            #expect(write.stderr == "error: could not lock config file \(target.path): Permission denied\n")
            #expect(write.status == 255)
        }
    }

    @Test("the home config must be inside the sandbox too")
    func homeConfigIsAuthorized() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        // The unscoped read outside a repository reads it too.
        for args in [["--global", "--get", "a.b"], ["--global", "a.b", "x"], ["--global", "--list"], ["a.b"]] {
            await #expect(throws: Sandbox.Denial.self) {
                try await self.git(["config"] + args, root: root, home: home, work: work,
                                   environment: ["HOME": outside.path])
            }
        }
        // Nothing was started out there.
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("unsetting a key with several values changes nothing and is status 5")
    func unsetOfAMultivalueKey() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = home.appendingPathComponent(".gitconfig")
        let contents = "[a]\n\tb = 1\n\tb = 2\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let result = try await git(["config", "--global", "--unset", "a.b"], root: root, home: home, work: work)
        #expect(result.stderr == "warning: a.b has multiple values\n")
        #expect(result.status == 5)
        #expect(try String(contentsOf: file, encoding: .utf8) == contents)
    }

    @Test("an empty GIT_CONFIG_GLOBAL or GIT_CONFIG_SYSTEM names a file called ''")
    func emptyConfigFileName() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        for (flag, variable) in [("--global", "GIT_CONFIG_GLOBAL"), ("--system", "GIT_CONFIG_SYSTEM")] {
            let environment = [variable: ""]
            let list = try await git(["config", flag, "--list"], root: root, home: home, work: work,
                                     environment: environment)
            #expect(list.stderr == "fatal: unable to read config file '': No such file or directory\n")
            #expect(list.status == 128)
            let write = try await git(["config", flag, "a.b", "c"], root: root, home: home, work: work,
                                      environment: environment)
            #expect(write.stderr == "error: could not write config file : Is a directory\n")
            #expect(write.status == 4)
        }
    }
}
#endif
