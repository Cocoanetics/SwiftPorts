import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct LsTree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls-tree",
        abstract: "List the contents of a tree object."
    )

    @Flag(name: .short, help: "Recurse into subdirectories.")
    var recursive: Bool = false

    @Flag(name: .customLong("name-only"),
          help: "Print only the name of each entry.")
    var nameOnly: Bool = false

    @Argument(help: "Tree-ish to inspect. Defaults to HEAD.")
    var treeish: String = "HEAD"

    func run() async throws {
        let client = CommandContext.gitClient()
        let entries = try await client.lsTree(
            treeish: treeish, recursive: recursive)
        for e in entries {
            // Real git suppresses the directory entries themselves under
            // `-r` (since you only want the leaf blobs); match that.
            if recursive && e.kind == .tree { continue }
            if nameOnly {
                Stdio.print(e.path)
            } else {
                Stdio.print("\(e.mode) \(e.kind.rawValue) \(e.sha)\t\(e.path)")
            }
        }
    }
}
