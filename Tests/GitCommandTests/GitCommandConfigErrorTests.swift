// Config files git refuses: bad syntax, a directory that isn't there.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git config errors")
struct GitCommandConfigErrorTests: ConfigTestHelpers {

    @Test("a file with bad syntax is git's \"bad config line\", and a file it supersedes is not read")
    func malformedConfig() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = home.appendingPathComponent(".gitconfig")
        try "[a]\n\tb = c\n[broken\n\tx = y\n".write(to: broken, atomically: true, encoding: .utf8)
        for args in [["--get", "a.b"], ["--list"], ["x.y", "z"]] {
            let result = try await git(["config", "--global"] + args, root: root, home: home, work: work)
            #expect(result.stderr == "fatal: bad config line 3 in file \(broken.path)\n")
            #expect(result.status == 128)
        }

        // GIT_CONFIG_GLOBAL supersedes ~/.gitconfig, which is then not read at all.
        let chosen = root.appendingPathComponent("chosen.cfg")
        try "[o]\n\ty = fine\n".write(to: chosen, atomically: true, encoding: .utf8)
        let ignored = try await git(["config", "--global", "--list"], root: root, home: home, work: work,
                                    environment: ["GIT_CONFIG_GLOBAL": chosen.path])
        #expect(ignored.stdout == "o.y=fine\n")
    }

    @Test("a config file in a directory that isn't there can't be locked")
    func missingDirectory() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("nodir/new.cfg")
        let environment = ["GIT_CONFIG_GLOBAL": target.path]
        for args in [["x.y", "z"], ["--unset", "x.y"]] {
            let result = try await git(["config", "--global"] + args, root: root, home: home, work: work,
                                       environment: environment)
            #expect(result.stderr == "error: could not lock config file \(target.path): No such file or directory\n")
            #expect(result.status == 255)
        }
        // A get finds nothing; the directory was not made.
        #expect(try await git(["config", "--global", "--get", "x.y"], root: root, home: home, work: work,
                              environment: environment).status == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("nodir").path))
    }
}
#endif
