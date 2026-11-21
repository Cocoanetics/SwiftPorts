import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit

extension LFSFilterTests {
    @Test("required filters reject unavailable directions", arguments: [GitFilterDirection.clean, .smudge])
    func requiredDirection(_ direction: GitFilterDirection) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try GitLFSKit.installFilter()
        defer { try? GitLFSKit.uninstallFilter() }
        try await host.run {
            let made = try await LFSFixture.make(host, "required")
            let git = made.client
            let file = made.directory.appendingPathComponent("a.lfs")
            let payload = Data("payload\n".utf8)
            try Data("*.lfs filter=lfs -text\n".utf8)
                .write(to: made.directory.appendingPathComponent(".gitattributes"))
            try payload.write(to: file)
            try await git.add(paths: [".gitattributes", "a.lfs"])
            _ = try await git.commit(message: "files", author: nil, allowEmpty: false)

            let key = direction == .clean ? "clean" : "smudge"
            let opposite = direction == .clean ? "smudge" : "clean"
            let configurations: [[String: String]] = [
                [:], [key: ""], ["process": ""], ["process": "", key: ""],
                [opposite: "git-lfs " + opposite], [opposite: "git-lfs " + opposite, key: ""],
                ["process": "", opposite: "git-lfs " + opposite],
                ["process": "", key: "git-lfs " + key]
            ]
            for configuration in configurations {
                for name in ["clean", "smudge", "process"] {
                    _ = try await git.configUnset("filter.lfs.\(name)")
                    if let value = configuration[name] { try await git.configSet("filter.lfs.\(name)", value) }
                }
                for required in [false, true] {
                    try await git.configSet("filter.lfs.required", required ? "true" : "false")
                    if direction == .clean {
                        try Data((required ? "required\n" : "changed\n").utf8).write(to: file)
                    } else {
                        try FileManager.default.removeItem(at: file)
                    }
                    do {
                        if direction == .clean {
                            try await git.add(paths: ["a.lfs"])
                        } else {
                            try await git.checkoutPaths(["a.lfs"])
                        }
                        #expect(!required, "Required \(key) succeeded with \(configuration)")
                        if !required, direction == .smudge {
                            #expect(try Data(contentsOf: file) == payload)
                        }
                    } catch let error as GitFilterError {
                        #expect(required)
                        #expect(error.driver == "lfs")
                        #expect(error.path == "a.lfs")
                        #expect(error.direction == direction)
                        #expect(error.reason == .failed(""))
                    }
                    if direction == .clean {
                        let entry = try #require(try await git.indexedEntries().first { $0.path == "a.lfs" })
                        let expected = required ? payload : Data("changed\n".utf8)
                        #expect(try await git.catFileBlob(entry.oid) == expected)
                    }
                    // Restore a known file/index for the next configuration.
                    try await git.configSet("filter.lfs.required", "false")
                    try payload.write(to: file)
                    try await git.add(paths: ["a.lfs"])
                }
            }
            // A configured required direction (or process) remains usable.
            for name in [key, "process"] {
                for previous in ["clean", "smudge", "process"] {
                    _ = try await git.configUnset("filter.lfs.\(previous)")
                }
                try await git.configSet("filter.lfs.\(name)", "git-lfs " + name)
                try await git.configSet("filter.lfs.required", "true")
                if direction == .clean {
                    try await git.add(paths: ["a.lfs"])
                } else {
                    try FileManager.default.removeItem(at: file)
                    try await git.checkoutPaths(["a.lfs"])
                    #expect(try Data(contentsOf: file) == payload)
                }
            }
        }
    }
}
