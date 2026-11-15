import ArgumentParser
import ShellKit
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
              git tag -s|-u <key> <name> -m <msg> [<commit>]
                                               create signed annotated tag
              git tag -d <name>                delete tag
              git tag -l <pattern>             list with glob filter
              git tag -n[<num>]                list including annotation lines
              git tag -f <name> [<commit>]     force-overwrite existing
              git tag -v <name>...             verify the tags' GPG signatures
            """
    )

    @Flag(name: [.customShort("a"), .customLong("annotate")],
          help: "Create an annotated tag (requires -m).")
    var annotate: Bool = false

    @Flag(name: [.customShort("s"), .customLong("sign")], inversion: .prefixedNo,
          help: "Create a signed annotated tag (tag.gpgsign when neither is given).")
    var sign: Bool?

    @Option(name: [.customShort("u"), .customLong("local-user")],
            help: "Sign the annotated tag with this key.")
    var localUser: String?

    @Flag(name: [.customShort("d"), .customLong("delete")],
          help: "Delete the named tag.")
    var delete: Bool = false

    @Flag(name: [.customShort("l"), .customLong("list")],
          help: "List tags. Implicit when no other flag and no name is given.")
    var list: Bool = false

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Replace an existing tag with the same name.")
    var force: Bool = false

    @Flag(name: [.customShort("v"), .customLong("verify")],
          help: "Verify the GPG signature of the given tags.")
    var verify: Bool = false

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
        if verify && (annotate || delete || list) {
            throw ValidationError("-v can't be combined with -a, -d or -l")
        }
    }

    func run() async throws {
        // Walk useRest and pull our known flags back out (`.captureForPassthrough`
        // freezes ArgumentParser at the first positional, so a user
        // typing `git tag -a v2.0 -m "..."` would have `-m` stuck in useRest).
        var positionals: [String] = []
        var pulledForce = force
        var pulledVerify = verify
        var pulledMessage = message
        var pulledAnnotate = annotate
        var pulledSign = sign
        var pulledKey = localUser
        var i = 0
        while i < rest.count {
            let tok = rest[i]
            if tok == "-a" || tok == "--annotate" { pulledAnnotate = true; i += 1; continue }
            if ["-s", "--sign", "--no-sign"].contains(tok) { pulledSign = tok != "--no-sign"; i += 1; continue }
            if tok == "-u" || tok == "--local-user", i + 1 < rest.count {
                pulledKey = rest[i + 1]
                i += 2; continue
            }
            if tok.hasPrefix("--local-user=") {
                pulledKey = String(tok.dropFirst("--local-user=".count))
                i += 1; continue
            }
            if tok == "-f" || tok == "--force" {
                pulledForce = true; i += 1; continue
            }
            if tok == "-v" || tok == "--verify" {
                pulledVerify = true; i += 1; continue
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

        // Verify path: only the tags' own refs, with their contents shown.
        if pulledVerify {
            if useForce || annotate || delete || list {
                throw CLIError.stderr(
                    "error: options '-v' and '-f', '-a', '-d' or '-l' cannot be used together", exitCode: 129)
            }
            guard !useRest.isEmpty else { throw ValidationError("tag name required") }
            try await VerifyTag.verify(useRest, inTagNamespace: true, verbose: true, raw: false)
            return
        }

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
                Shell.print("Deleted tag '\(name)' (was \(short))")
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
                    Shell.print("\(entry.name.padding(toLength: 16, withPad: " ", startingAt: 0))\(entry.summary)")
                }
            } else {
                let names = try await client.tagList(pattern: useRest.first)
                for name in names { Shell.print(name) }
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

        // As in git, signing (-s, -u, tag.gpgsign) or a message makes
        // the tag an annotated one.
        let signMode = try await client.tagSignMode(
            sign: pulledSign, keyID: pulledKey, annotate: pulledAnnotate, message: useMessage != nil)
        if pulledAnnotate || useMessage != nil || signMode != .noSign {
            guard let resolved = useMessage else {
                throw CLIError.stderr(
                    "fatal: --annotate requires --message", exitCode: 128)
            }
            do {
                _ = try await client.tagCreateAnnotated(
                    name: name, target: target, message: resolved,
                    tagger: nil, force: useForce, sign: signMode)
            } catch let failure as SwiftGit.GitClient.SigningFailure {
                if let fatal = failure.fatal { throw CLIError.stderr("fatal: \(fatal)", exitCode: 128) }
                let left = try await Self.editMessagePath(client)
                throw CLIError.stderr(["error: unable to sign the tag", "The tag message has been left in \(left)"],
                                      exitCode: 128)
            }
        } else {
            _ = try await client.tagCreate(
                name: name, target: target, force: useForce)
        }
    }

    /// Where git says it left the tag message, `TAG_EDITMSG` in the git
    /// directory, named from the top of the work tree as git names it.
    private static func editMessagePath(_ client: SwiftGit.GitClient) async throws -> String {
        func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let directory = real(try await client.gitDir() ?? ".git")
        guard let top = try await client.toplevel().map(real), directory.hasPrefix(top + "/") else {
            return directory + "/TAG_EDITMSG"
        }
        return directory.dropFirst(top.count + 1) + "/TAG_EDITMSG"
    }
}
