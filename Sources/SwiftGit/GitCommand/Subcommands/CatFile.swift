import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct CatFile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cat-file",
        abstract: "Provide content or type/size info about a git object."
    )

    @Flag(name: .customShort("t"),
          help: "Show the object type.")
    var typeOnly: Bool = false

    @Flag(name: .customShort("s"),
          help: "Show the object size in bytes.")
    var sizeOnly: Bool = false

    @Flag(name: .customShort("e"),
          help: "Exit 0 if the object exists; non-zero otherwise.")
    var existsOnly: Bool = false

    @Flag(name: .customShort("p"),
          help: "Pretty-print the object's contents.")
    var pretty: Bool = false

    @Argument(help: "Revision-spec or SHA.")
    var object: String

    func run() async throws {
        let client = CommandContext.gitClient()

        // -e: silently succeed/fail. Skip the metadata read errors and
        // surface the same exit code real git does (1 for missing).
        if existsOnly {
            do {
                _ = try await client.objectMetadata(of: object)
            } catch {
                throw ExitCode(1)
            }
            return
        }

        if typeOnly {
            let meta = try await client.objectMetadata(of: object)
            Stdio.print(meta.kind.rawValue)
            return
        }
        if sizeOnly {
            let meta = try await client.objectMetadata(of: object)
            Stdio.print(meta.size)
            return
        }
        if pretty {
            // We support blobs only for `-p` — tree/commit pretty-print
            // would need its own structured emitter, and most callers
            // hit blobs. Tag/commit pretty-print is a follow-up.
            let meta = try await client.objectMetadata(of: object)
            switch meta.kind {
            case .blob:
                let data = try await client.catFileBlob(object)
                Stdio.stdout.write(data)
            default:
                throw CLIError.stderr(
                    "fatal: pretty-print for \(meta.kind.rawValue) objects is not yet supported",
                    exitCode: 1)
            }
            return
        }
        // No mode flag: real git errors out with usage. Same here.
        throw CLIError.stderr(
            "usage: git cat-file (-t | -s | -e | -p) <object>",
            exitCode: 129)
    }
}
