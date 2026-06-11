import Foundation
import ShellKit
import Testing
@testable import ZipKit

/// Error messages carry resolved (host) URLs as payload; their
/// rendered descriptions must fold those back to the script-visible
/// spelling under a path-mapped sandbox, and stay the identity
/// without one (issue #66).
@Suite struct ZipKitErrorDisplayPathTests {

    @Test func descriptionsFoldHostPathsUnderPathMapping() throws {
        let host = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipkit-err-\(UUID().uuidString)",
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
            let target = host.appendingPathComponent("out.txt")
            let exists = ZipKitError.destinationExists(target)
            #expect(exists.errorDescription ==
                "Destination already exists: /work/out.txt "
                + "(use --overwrite or --never-overwrite to choose)")
            let write = ZipKitError.writeFailed(target, underlying: "boom")
            #expect(write.errorDescription ==
                "Couldn't write /work/out.txt: boom")
            // The host layout must not leak into either message.
            #expect(exists.errorDescription?.contains(host.path) == false)
            #expect(write.errorDescription?.contains(host.path) == false)
        }
    }

    @Test func descriptionsAreIdentityWithoutMapping() {
        let err = ZipKitError.destinationExists(
            URL(fileURLWithPath: "/tmp/plain/out.txt"))
        #expect(err.errorDescription ==
            "Destination already exists: /tmp/plain/out.txt "
            + "(use --overwrite or --never-overwrite to choose)")
    }
}
