import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Tag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "Create, list, delete, or verify tag refs.",
        discussion: """
            Forms supported:
              git tag                          list tags
              git tag <name> [<commit>]        create lightweight tag
              git tag -a <name> -m <msg> [<commit>]
                                               create annotated tag
              git tag -d <name>                delete tag
              git tag -l <pattern>             list with glob filter
              git tag -n[<num>]                list including annotation lines
              git tag -f <name> [<commit>]     force-overwrite existing
            """
    )

    @Flag(name: [.customShort("a"), .customLong("annotate")],
          help: "Create an annotated tag (requires -m).")
    var annotate: Bool = false

    @Flag(name: [.customShort("d"), .customLong("delete")],
          help: "Delete the named tag.")
    var delete: Bool = false

    @Flag(name: [.customShort("l"), .customLong("list")],
          help: "List tags. Implicit when no other flag and no name is given.")
    var list: Bool = false

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Replace an existing tag with the same name.")
    var force: Bool = false

    @Flag(name: .customShort("n"),
          help: "When listing, also show the first line of each tag's annotation.")
    var withAnnotation: Bool = false

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Annotation message (with -a).")
    var message: String?

    @Argument(parsing: .captureForPassthrough,
              help: "Tag name and optional <commit>, or pattern when listing.")
    var rest: [String] = []

    func validate() throws {
        if annotate && delete {
            throw ValidationError("-a and -d are mutually exclusive")
        }
    }

    func run() async throws {
        // Walk useRest and pull our known flags back out (`.captureForPassthrough`
        // freezes ArgumentParser at the first positional, so a user
        // typing `git tag -a v2.0 -m "..."` would have `-m` stuck in useRest).
        var positionals: [String] = []
        var pulledForce = force
        var pulledMessage = message
        var i = 0
        while i < rest.count {
            let tok = rest[i]
            if tok == "-f" || tok == "--force" {
                pulledForce = true; i += 1; continue
            }
            if tok == "-m" || tok == "--message", i + 1 < rest.count {
                pulledMessage = rest[i + 1]
                i += 2; continue
            }
            if tok.hasPrefix("--message=") {
                pulledMessage = String(tok.dropFirst("--message=".count))
                i += 1; continue
            }
            positionals.append(tok)
            i += 1
        }
        let useForce = pulledForce
        let useMessage = pulledMessage
        let useRest = positionals

        let client = CommandContext.gitClient()

        // Delete path.
        if delete {
            for name in useRest {
                let oldSHA: String
                do {
                    oldSHA = try await client.tagDelete(name: name)
                } catch let err as Libgit2Error
                    where err.message.lowercased().contains("not found") {
                    throw CLIError.stderr(
                        "error: tag '\(name)' not found.", exitCode: 1)
                }
                let short = String(oldSHA.prefix(7))
                Stdio.print("Deleted tag '\(name)' (was \(short))")
            }
            return
        }

        // List path: explicit -l / -n, or no positional arg.
        if list || withAnnotation || useRest.isEmpty {
            if withAnnotation {
                let entries = try await client.tagDetails(
                    pattern: useRest.first)
                for entry in entries {
                    // Real git pads the name to 16 chars before the
                    // summary text. Match that.
                    Stdio.print("\(entry.name.padding(toLength: 16, withPad: " ", startingAt: 0))\(entry.summary)")
                }
            } else {
                let names = try await client.tagList(pattern: useRest.first)
                for name in names { Stdio.print(name) }
            }
            return
        }

        // Create path.
        guard let name = useRest.first else {
            throw ValidationError("tag name required")
        }
        let target = useRest.count > 1 ? useRest[1] : "HEAD"

        if !force, (try? await client.tagExists(name)) == true {
            throw CLIError.stderr(
                "fatal: tag '\(name)' already exists", exitCode: 128)
        }

        if annotate {
            guard let resolved = useMessage else {
                throw CLIError.stderr(
                    "fatal: --annotate requires --message", exitCode: 128)
            }
            _ = try await client.tagCreateAnnotated(
                name: name, target: target, message: resolved,
                tagger: nil, force: useForce)
        } else {
            _ = try await client.tagCreate(
                name: name, target: target, force: useForce)
        }
    }
}
