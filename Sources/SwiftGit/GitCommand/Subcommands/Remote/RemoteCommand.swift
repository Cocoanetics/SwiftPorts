import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

/// `git remote` is two-faced: a parent dispatcher for `add`/`remove`/
/// `rename`/`get-url`/`set-url`, AND a list-printer when invoked
/// alone or with `-v`. Real git encodes both in one command; we do
/// the same by accepting `-v` at the parent level and dispatching
/// to the list-printer when no subcommand is given.
struct RemoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "Manage remote tracking repositories.",
        subcommands: [
            RemoteAdd.self,
            RemoteGetURL.self,
            RemoteRemove.self,
            RemoteRename.self,
            RemoteSetURL.self,
        ]
    )

    @Flag(name: [.customShort("v"), .customLong("verbose")],
          help: "When listing, print the URL alongside each remote name.")
    var verbose: Bool = false

    func run() async throws {
        let client = CommandContext.gitClient()
        let names = try await client.remoteList()
        if !verbose {
            for name in names { Stdio.print(name) }
            return
        }
        for name in names {
            if let url = try await client.remoteURL(named: name) {
                Stdio.print("\(name)\t\(url.absoluteString) (fetch)")
                Stdio.print("\(name)\t\(url.absoluteString) (push)")
            }
        }
    }
}
