import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit

extension LFSFilterTests {
    @Test("required command gating matches clean and streamable checkout",
           arguments: [GitFilterDirection.clean, .smudge])
    func requiredDirection(_ direction: GitFilterDirection) async throws {
        try await LFSStreamFixture.run { _, git, directory in
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            let file = directory.appendingPathComponent("a.lfs")
            let payload = Data("payload\n".utf8)
            try Data("*.lfs filter=lfs -text\n".utf8)
                .write(to: directory.appendingPathComponent(".gitattributes"))
            try payload.write(to: file)
            try await git.add(paths: [".gitattributes", "a.lfs"])
            _ = try await git.commit(message: "files", author: nil, allowEmpty: false)
            let key = direction == .clean ? "clean" : "smudge"
            let opposite = direction == .clean ? "smudge" : "clean"
            let configurations: [[String: String]] = [
                [:], [key: ""], ["process": ""], ["process": "", key: ""],
                [opposite: "git-lfs " + opposite], [opposite: "git-lfs " + opposite, key: ""]
            ]
            for configuration in configurations {
                for name in ["clean", "smudge", "process"] {
                    _ = try await git.configUnset("filter.lfs.\(name)")
                    if let value = configuration[name] { try await git.configSet("filter.lfs.\(name)", value) }
                }
                for required in [false, true] {
                    try await git.configSet("filter.lfs.required", required ? "true" : "false")
                    if required && (direction == .clean || configuration["process"] != nil
                        || configuration[key] != nil) {
                        if direction == .clean {
                            await #expect(throws: GitFilterError.self) { try await git.add(paths: ["a.lfs"]) }
                        } else {
                            try FileManager.default.removeItem(at: file)
                            await #expect(throws: GitFilterError.self) { try await git.checkoutPaths(["a.lfs"]) }
                        }
                        continue
                    }
                    if direction == .clean {
                        try await git.add(paths: ["a.lfs"])
                        let entry = try #require(try await git.indexedEntries().first { $0.path == "a.lfs" })
                        #expect(try await git.catFileBlob(entry.oid) == payload)
                    } else {
                        try FileManager.default.removeItem(at: file)
                        try await git.checkoutPaths(["a.lfs"])
                        #expect(try Data(contentsOf: file) == payload)
                    }
                }
            }
        }
    }
}
