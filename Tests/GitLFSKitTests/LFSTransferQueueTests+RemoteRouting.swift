import Foundation
import ShellKit
import SwiftGit
import Testing
@testable import GitLFSKit

extension LFSTransferQueueTests {
    @Test("explicit URL remotes route fetch, object-id push and pre-push away from origin",
          arguments: ["fetch", "push", "pre-push"])
    func explicitRemoteRouting(_ command: String) async throws {
        let remote = "https://backup.example/repo.git"
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                #expect(request.url?.absoluteString == remote + "/info/lfs/objects/batch")
                return .batch(request, operation: command == "fetch" ? "download" : "upload")
            }
            return LFSTransferReply(body: command == "fetch" ? data : Data())
        }
        try await run(config: [("lfs.locksverify", "false")]) { client, store, directory in
            let git = GitClient(workingDirectory: directory)
            let pointer = Pointer(oid: oid, size: Int64(data.count))
            try Data(pointer.encoded.utf8).write(to: directory.appendingPathComponent("file.bin"))
            try await git.add(paths: ["file.bin"])
            let tip = try await git.commit(message: "pointer", author: nil, allowEmpty: false)
            if command != "fetch" { try data.write(to: try await store.objectPath(oid)) }
            let result: LFSCommandResult
            switch command {
            case "fetch":
                result = try await FetchOptions().run([remote, "HEAD"], client: client, git: git)
            case "push":
                var options = PushOptions()
                options.objectID = true
                result = try await options.run([remote, oid], client: client, git: git)
            default:
                let line = "refs/heads/main \(tip) refs/heads/main \(String(repeating: "0", count: 40))\n"
                let shell = Shell(stdin: .data(Data(line.utf8)), environment: Shell.current.environment)
                shell.sandbox = Shell.current.sandbox
                result = try await shell.withCurrent {
                    try await PrePushOptions().run([remote, remote], client: client, git: git)
                }
            }
            #expect(result.status == 0, "\(result.stderr)")
            #expect(LFSTransferURLProtocol.requests.contains { $0.url?.lastPathComponent == "batch" })
        }
    }
}
