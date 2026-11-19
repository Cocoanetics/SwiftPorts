import Foundation

extension LFSEndpointFinder {
    /// `config.Remote`, then `lfs.remote.autodetect` when it is on
    /// (`git.FirstRemoteForTreeish` of HEAD, as the smudge filter does).
    public func downloadRemote() async -> String {
        let configured = configuredDownloadRemote()
        guard LFSConfiguration.bool(configuration.get("lfs.remote.autodetect"), fallback: false) else {
            return configured
        }
        if let detected = await remoteContainingHEAD() { return detected }
        return configured
    }

    /// `config.PushRemote`: `branch.<name>.pushRemote`, then
    /// `remote.lfsPushDefault`, then `remote.pushDefault`, then the download remote.
    /// Autodetect is a download-side choice and is not applied here.
    public func uploadRemote() -> String {
        if let branch, !branch.isEmpty,
           let remote = configuration.get("branch.\(branch).pushremote"), !remote.isEmpty {
            return remote
        }
        if let remote = configuration.get("remote.lfspushdefault"), !remote.isEmpty { return remote }
        if let remote = configuration.get("remote.pushdefault"), !remote.isEmpty { return remote }
        return configuredDownloadRemote()
    }

    /// `lfs.remote.searchall`: the selected remote, then every other remote in
    /// the order it was first configured. With the option off, only the selected one.
    /// git-lfs reads the option and has no caller for it; this is that list.
    public func candidateRemotes(operation: String) async -> [String] {
        let selected = operation == "upload" ? uploadRemote() : await downloadRemote()
        guard LFSConfiguration.bool(configuration.get("lfs.remote.searchall"), fallback: false) else {
            return [selected]
        }
        return [selected] + configuration.remotes.filter { $0 != selected }
    }

    /// `config.Remote` without autodetect. `git lfs env` uses this.
    func configuredDownloadRemote() -> String {
        if let branch, !branch.isEmpty,
           let remote = configuration.get("branch.\(branch).remote"), !remote.isEmpty {
            return remote
        }
        if let remote = configuration.get("remote.lfsdefault"), !remote.isEmpty { return remote }
        if configuration.remotes.count == 1, let only = configuration.remotes.first { return only }
        return "origin"
    }

    /// `remoteForRef` over `git branch -r --contains HEAD`. A remote whose
    /// name contains `/` makes the ref ambiguous, and the result is then nil.
    private func remoteContainingHEAD() async -> String? {
        if remoteNames.contains(where: { $0.contains("/") }) { return nil }
        guard let head = try? await client.resolveOID("HEAD") else { return nil }
        guard let branches = try? await client.remoteBranches() else { return nil }
        for branch in branches {
            guard let ancestor = try? await client.mergeBase(head, branch.targetSHA) else { continue }
            guard ancestor.caseInsensitiveCompare(head) == .orderedSame else { continue }
            let remote = Self.remoteName(in: branch.name)
            if !remote.isEmpty { return remote }
        }
        return nil
    }

    /// The first `/`-separated component of a remote-tracking name (`origin/main`).
    static func remoteName(in refname: String) -> String {
        let trimmed = refname.trimmingCharacters(in: .whitespaces)
        let pieces = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let head = pieces.first.map(String.init) ?? trimmed
        let parts = head.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty else { return "" }
        return parts[0]
    }
}
