import ArgumentParser
import Foundation
import GitHub
import ForgeKit
import Sandbox

struct RunDownload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download workflow run artifacts.",
        discussion: """
        Without --pattern / --name, every artifact in the run is
        downloaded. Each artifact is saved as <name>.zip in --dir.
        """
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Run ID.")
    var id: Int

    @Option(name: [.customShort("n"), .customLong("name")],
            parsing: .singleValue,
            help: "Match artifact by exact name; repeatable.")
    var names: [String] = []

    @Option(name: [.customShort("p"), .customLong("pattern")],
            parsing: .singleValue,
            help: "Glob pattern for artifact names; repeatable.")
    var patterns: [String] = []

    @Option(name: [.customShort("D"), .customLong("dir")],
            help: "Destination directory. Created if missing.")
    var directory: String = "."

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()

        let envelope: WorkflowArtifactList = try await client.get(
            "repos/\(target.slug)/actions/runs/\(id)/artifacts")

        let matching = envelope.artifacts.filter { artifact in
            if !names.isEmpty || !patterns.isEmpty {
                if names.contains(artifact.name) { return true }
                if patterns.contains(where: { glob($0, matches: artifact.name) }) {
                    return true
                }
                return false
            }
            return true
        }
        guard !matching.isEmpty else {
            let available = envelope.artifacts.map(\.name).joined(separator: ", ")
            throw ValidationError(
                "No artifacts matched. Available: " +
                (available.isEmpty ? "(none)" : available))
        }

        let destDir = Sandbox.resolve(directory)
        try await Sandbox.authorize(destDir)
        try FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true)

        for artifact in matching where !artifact.expired {
            let dest = destDir.appendingPathComponent("\(artifact.name).zip")
            try await Sandbox.authorize(dest)
            let size = ByteCountFormatter.string(
                fromByteCount: artifact.sizeInBytes, countStyle: .file)
            Stdio.print("→ \(artifact.name).zip (\(size))")
            // raw() returns the body bytes; URLSession follows the
            // 302 redirect to the signed S3 download URL by default.
            // The redirect target is below the Swift boundary —
            // `client.raw()`'s url is what's gated above by
            // `APIClient.perform`.
            let response = try await client.raw(
                method: .get,
                path: "repos/\(target.slug)/actions/artifacts/\(artifact.id)/zip")
            try response.body.write(to: dest)
        }
        let expired = matching.filter(\.expired)
        if !expired.isEmpty {
            Stdio.print(ANSI.dim(
                "Skipped \(expired.count) expired: " +
                expired.map(\.name).joined(separator: ", ")))
        }
        Stdio.print("\(ANSI.green("✓")) Downloaded \(matching.count - expired.count) artifact(s) to \(destDir.path)")
    }

    /// Same minimal `*` / `?` glob as `gh release download`.
    private func glob(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        var memo: [[Bool?]] = Array(
            repeating: Array(repeating: nil, count: n.count + 1),
            count: p.count + 1)
        func match(_ i: Int, _ j: Int) -> Bool {
            if let cached = memo[i][j] { return cached }
            let result: Bool
            if i == p.count { result = j == n.count }
            else if p[i] == "*" {
                result = match(i + 1, j) || (j < n.count && match(i, j + 1))
            } else if j < n.count && (p[i] == "?" || p[i] == n[j]) {
                result = match(i + 1, j + 1)
            } else {
                result = false
            }
            memo[i][j] = result
            return result
        }
        return match(0, 0)
    }
}
