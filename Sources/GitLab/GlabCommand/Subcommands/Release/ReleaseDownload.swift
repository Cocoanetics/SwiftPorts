import ArgumentParser
import Foundation
import Sandbox
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives in a separate module on Linux
#endif
import GitLab

struct ReleaseDownload: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download a release's assets.",
        discussion: """
        Downloads matching assets to the destination directory.

        Without --pattern, all asset links are downloaded. Use --sources
        to also include the auto-generated source archives.
        """
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("p"), .customLong("pattern")],
            parsing: .singleValue,
            help: "Glob to match asset names; repeatable.")
    var patterns: [String] = []

    @Option(name: [.customShort("D"), .customLong("dir")],
            help: "Destination directory.")
    var directory: String = "."

    @Flag(name: .customLong("sources"),
          help: "Also download the auto-generated source archives (zip, tar.gz, …).")
    var sources: Bool = false

    @Argument(help: "Tag name of the release to download.")
    var tagName: String

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let encoded = tagName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? tagName
        let release: Release = try await client.get(
            "projects/\(target.encodedPath)/releases/\(encoded)")

        // Collect (name, url) pairs from links and (optionally) sources.
        var pairs: [(name: String, url: URL)] = []
        for link in release.assets?.links ?? [] {
            pairs.append((name: link.name, url: link.url))
        }
        if sources {
            for src in release.assets?.sources ?? [] {
                let last = src.url.lastPathComponent
                let name = last.isEmpty ? "\(release.tagName).\(src.format)" : last
                pairs.append((name: name, url: src.url))
            }
        }

        let matching = pairs.filter { p in
            patterns.isEmpty || patterns.contains { fnmatch(pattern: $0, name: p.name) }
        }
        guard !matching.isEmpty else {
            let names = pairs.map(\.name).joined(separator: ", ")
            throw ValidationError(
                "No assets matched. Available: \(names.isEmpty ? "(none)" : names)")
        }

        let destDir = Sandbox.resolve(directory)
        try await Sandbox.authorize(destDir)
        try FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true)

        // Linux's swift-corelibs-foundation doesn't expose
        // `URLSession.shared`; instantiate explicitly so the same code
        // builds on every platform.
        let session = URLSession(configuration: .default)
        for asset in matching {
            let dest = destDir.appendingPathComponent(asset.name)
            try await Sandbox.authorize(asset.url)
            try await Sandbox.authorize(dest)
            Stdio.print("→ \(asset.name)")
            let (data, _) = try await session.data(from: asset.url)
            try data.write(to: dest)
        }
    }

    /// Minimal `fnmatch` — supports `*` and `?`. No bracket classes.
    private func fnmatch(pattern: String, name: String) -> Bool {
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
