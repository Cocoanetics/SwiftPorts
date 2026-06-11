import Foundation
import ForgeKit
import RipgrepKit
import ShellKit

/// Argv-level entry point. Builds a `Ripgrep.Configuration` from
/// command-line arguments and runs the engine. Returns the process
/// exit code (0 = match found, 1 = no match, 2 = error). Kept in its
/// own enum (mirroring the `JqExecutable` shape) so embedders can
/// drive the CLI behavior in-process.
public enum RgExecutable {

    /// `stdinIsReadable` decides the no-path default: search `stdin`
    /// when true, walk the cwd when false. Defaults to the host
    /// process's fd 0 (`TTY.isStdinReadable`); tests pass it
    /// explicitly so the routing doesn't depend on the harness.
    @discardableResult
    public static func run(argv: [String],
                           stdin: InputSource,
                           stdout: OutputSink,
                           stderr: OutputSink,
                           stdinIsReadable: Bool = TTY.isStdinReadable
    ) async throws -> Int32 {
        do {
            let parsed = try Parser.parse(argv)

            // Built-in commands that exit early without running a search.
            switch parsed.specialMode {
            case .help:
                stdout.write(Parser.helpText)
                return 0
            case .version:
                stdout.write("rg 0.1.0 (swift-ports)\n")
                return 0
            case .typeList:
                emitTypeList(registry: parsed.config.walker.typeRegistry,
                             to: stdout)
                return 0
            case .files:
                return try runFilesMode(parsed: parsed, stdout: stdout)
            case .none:
                break
            }

            // Resolve roots — empty argv means cwd or stdin. Stdin
            // wins only when it's actually readable input (pipe /
            // file / socket); a terminal, a GUI or CI host's
            // `/dev/null`, or a closed fd all mean "no stdin", and
            // real rg walks the cwd there. Gating on `!isStdinTTY`
            // read empty stdin in those environments and reported
            // no matches (issue #65).
            let resolvedRoots: [(URL, String)]
            if parsed.paths.isEmpty {
                if stdinIsReadable {
                    resolvedRoots = []  // engine reads stdin
                } else {
                    // Default-cwd search: real rg searches "./" but
                    // strips the prefix for display (`a.txt`, not
                    // `./a.txt`); root display "." gives the Walker
                    // the same shape.
                    resolvedRoots = [(Shell.currentDirectory, ".")]
                }
            } else {
                resolvedRoots = parsed.paths.map { p -> (URL, String) in
                    if p == "-" { return (URL(fileURLWithPath: "-"), "<stdin>") }
                    return (Shell.resolve(p), p)
                }
            }

            // Validate every supplied path *before* running the search.
            // A missing input is an error condition in real rg (exit 2),
            // not "found no matches" (exit 1); scripts gating on the
            // exit code rely on that distinction.
            var sawMissingPath = false
            for (url, display) in resolvedRoots where url.path != "-" {
                try await Shell.authorize(url)
                if !FileManager.default.fileExists(atPath: url.path) {
                    stderr.write(
                        "rg: \(display): No such file or directory\n")
                    sawMissingPath = true
                }
            }

            let outcome = try await Ripgrep.run(
                configuration: parsed.config,
                roots: resolvedRoots.map {
                    Walker.Root(url: $0.0, display: $0.1)
                },
                stdin: stdin,
                stdout: stdout,
                stderr: stderr)

            // Real rg's exit codes:
            //   0 — at least one match
            //   1 — no match
            //   2 — error
            if sawMissingPath { return 2 }
            return outcome.hadMatch ? 0 : 1
        } catch let err as Parser.ArgError {
            stderr.write("rg: \(err.message)\n")
            return 2
        } catch let err as PatternError {
            stderr.write("rg: \(err.description)\n")
            return 2
        } catch {
            stderr.write("rg: \(error)\n")
            return 2
        }
    }

    /// `--files` mode — emit the list of files that would be searched,
    /// one per line, without running the pattern matcher.
    private static func runFilesMode(
        parsed: Parser.ParsedArgs,
        stdout: OutputSink
    ) throws -> Int32 {
        let roots: [Walker.Root] = parsed.paths.isEmpty
            ? [Walker.Root(url: Shell.currentDirectory, display: ".")]
            : parsed.paths.map { Walker.Root(url: Shell.resolve($0), display: $0) }
        let walker = Walker(options: parsed.config.walker)
        var count = 0
        try walker.walk(roots: roots) { entry in
            stdout.write(entry.displayPath + "\n")
            count += 1
        }
        return count > 0 ? 0 : 1
    }

    /// Render `--type-list` output: one line per type, `aliases: globs…`.
    private static func emitTypeList(
        registry: TypeRegistry,
        to stdout: OutputSink
    ) {
        let listing = registry.listing()
        for (name, globs) in listing {
            stdout.write("\(name): \(globs.joined(separator: ", "))\n")
        }
    }
}
