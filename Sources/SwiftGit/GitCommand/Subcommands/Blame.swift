import ArgumentParser
import Foundation
import Sandbox
import SwiftGit

/// `git blame <path>`: show, for each line, the commit that last
/// changed it. Output format mirrors real git's default:
/// `<sha7> (<author> <date>  <line>) <text>`.
struct Blame: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blame",
        abstract: "Show what revision and author last modified each line of a file."
    )

    @Argument(help: "Path to blame.")
    var path: String

    func run() async throws {
        let client = CommandContext.gitClient()
        let hunks = try await client.blame(path: path)

        // Read the file from disk (real git pairs blame with the
        // working-tree content; for committed-only blame, swap to
        // git_blob_lookup of the latest commit's tree).
        let url = Sandbox.resolve(path)
        try await Sandbox.authorize(url)
        let body: String
        do {
            body = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CLIError.stderr(
                "fatal: no such path '\(path)' in HEAD",
                exitCode: 128)
        }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)

        // Walk every line; for each, find the hunk it belongs to.
        var hunkByLine: [Int: BlameHunk] = [:]
        for hunk in hunks {
            for offset in 0..<hunk.linesInHunk {
                hunkByLine[hunk.startLine + offset] = hunk
            }
        }

        let stdout = Stdio.stdout
        for (idx, line) in lines.enumerated() {
            let lineNo = idx + 1
            guard let hunk = hunkByLine[lineNo] else { continue }
            let date = Date(timeIntervalSince1970: hunk.authorTime)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            f.locale = Locale(identifier: "en_US_POSIX")
            let dateStr = f.string(from: date)
            let header = "\(hunk.shortSHA) (\(pad(hunk.authorName, to: 16)) \(dateStr)  \(lineNo))"
            stdout.write(Data("\(header) \(line)\n".utf8))
        }
    }

    private func pad(_ s: String, to width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }
}
