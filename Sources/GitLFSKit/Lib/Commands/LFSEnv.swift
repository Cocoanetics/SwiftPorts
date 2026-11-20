import SwiftGit

/// `commands/command_env.go` and `lfs.Environ`. Reads configuration without
/// starting transfers, authenticating SSH, or probing a server.
public enum LFSEnv {
    public static func run(client: GitClient) async -> LFSCommandResult {
        let finder = await LFSEndpointFinder(client, showConfigWarnings: true)
        let config = finder.configuration
        let paths = await LFSRepositoryPaths.load(client, configuration: config)
        var lines = [LFSVersion.string, PortVersion.gitLine, ""]
        for row in finder.environmentReport() {
            lines.append("\(row.key)=\(row.endpoint.url) (auth=\(finder.access(for: row.endpoint.url).mode))")
            let ssh = row.endpoint.ssh
            if !ssh.userAndHost.isEmpty { lines.append("  SSH=\(ssh.userAndHost):\(ssh.path)") }
        }
        let download = finder.endpoint(operation: "download", remote: finder.configuredDownloadRemote())
        let upload = finder.endpoint(operation: "upload", remote: finder.uploadRemote())
        let pruneRemote = config.get("lfs.pruneremotetocheck") ?? ""
        lines += [
            "LocalWorkingDir=\(paths.working)",
            "LocalGitDir=\(paths.git)",
            "LocalGitStorageDir=\(paths.common)",
            "LocalMediaDir=\(paths.media)",
            "LocalReferenceDirs=\(paths.references.joined(separator: ", "))",
            "TempDir=\(paths.temporary)",
            "ConcurrentTransfers=\(config.integer("lfs.concurrenttransfers", fallback: 8))",
            "TusTransfers=\(config.boolean("lfs.tustransfers"))",
            "BasicTransfersOnly=\(config.boolean("lfs.basictransfersonly"))",
            "SkipDownloadErrors=\(config.skipDownloadErrors)",
            "FetchRecentAlways=\(config.boolean("lfs.fetchrecentalways"))",
            "FetchRecentRefsDays=\(config.integer("lfs.fetchrecentrefsdays", fallback: 7))",
            "FetchRecentCommitsDays=\(config.integer("lfs.fetchrecentcommitsdays", fallback: 0))",
            "FetchRecentRefsIncludeRemotes=\(config.boolean("lfs.fetchrecentremoterefs", fallback: true))",
            "PruneOffsetDays=\(config.integer("lfs.pruneoffsetdays", fallback: 3))",
            "PruneVerifyRemoteAlways=\(config.boolean("lfs.pruneverifyremotealways"))",
            "PruneVerifyUnreachableAlways=\(config.boolean("lfs.pruneverifyunreachablealways"))",
            "PruneRemoteName=\(pruneRemote.isEmpty ? "origin" : pruneRemote)",
            "LfsStorageDir=\(paths.storage)",
            "AccessDownload=\(finder.access(for: download.url).mode)",
            "AccessUpload=\(finder.access(for: upload.url).mode)",
            "DownloadTransfers=\(LFSTransferListing.names(config, upload: false))",
            "UploadTransfers=\(LFSTransferListing.names(config, upload: true))"
        ]
        for (key, label) in [("lfs.fetchexclude", "FetchExclude"), ("lfs.fetchinclude", "FetchInclude")] {
            let paths = config.fetchPaths(key)
            if !paths.isEmpty { lines.append("\(label)=\(paths.joined(separator: ", "))") }
        }
        lines += config.extensionLines
        lines += LFSEnvironment.gitEntries()
        for key in ["filter.lfs.process", "filter.lfs.smudge", "filter.lfs.clean"] {
            lines.append("git config \(key) = \((config.get(key) ?? "").goQuoted)")
        }
        return LFSCommandResult(stdout: lines.joined(separator: "\n") + "\n")
    }
}
