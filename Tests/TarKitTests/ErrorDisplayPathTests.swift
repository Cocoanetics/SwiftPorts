import Foundation
import ShellKit
import Testing
@testable import TarKit

/// Error messages carry resolved (host) URLs as payload; their
/// rendered descriptions must fold those back to the script-visible
/// spelling under a path-mapped sandbox, and stay the identity
/// without one (issue #66).
@Suite struct TarKitErrorDisplayPathTests {

    @Test func descriptionsFoldHostPathsUnderPathMapping() throws {
        let host = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarkit-err-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: host) }

        let mapping = PathMapping(mounts: [
            .init(virtual: "/work", host: host.path)
        ])
        var env = Environment()
        env.workingDirectory = "/work"
        let shell = Shell(environment: env)
        shell.sandbox = .confined(to: mapping, home: "/work")

        Shell.$current.withValue(shell) {
            let target = host.appendingPathComponent("backup.tar")
            let write = TarKitError.writeFailed(target, underlying: "boom")
            #expect(write.errorDescription ==
                "tar: cannot write '/work/backup.tar': boom")
            let read = TarKitError.readFailed(target, underlying: "gone")
            #expect(read.errorDescription ==
                "tar: cannot read '/work/backup.tar': gone")
            #expect(write.errorDescription?.contains(host.path) == false)
        }
    }

    @Test func descriptionsAreIdentityWithoutMapping() {
        let err = TarKitError.writeFailed(
            URL(fileURLWithPath: "/tmp/plain/backup.tar"),
            underlying: "boom")
        #expect(err.errorDescription ==
            "tar: cannot write '/tmp/plain/backup.tar': boom")
    }
}
