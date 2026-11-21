import Foundation
import SwiftGit

extension LFSClient {
    /// `uploadForRefUpdates` and `uploadContext` (git-lfs 3.7.1
    /// `commands/uploader.go`), as `git lfs pre-push` runs them.
    ///
    /// An update whose local OID is zero (a deletion) is skipped. Each other
    /// update scans the objects reachable from its local OID and not from
    /// any update's differing remote OID or the remote's cached branches
    /// (`ScanMultiRangeToRemote`). No path filter applies. Every object goes
    /// through the upload queue once; the server skips the ones it already has.
    ///
    /// `remoteBranches` is what `git ls-remote --heads <remote>` lists
    /// (`git.RemoteRefs`), as `main` or `refs/heads/main`. As in
    /// `calcSkippedRefs`, only the `refs/remotes/<remote>/*` tips whose branch
    /// the remote still has are excluded, so a branch deleted on the server
    /// (whose objects it may have collected) is uploaded again. When none of
    /// them is listed — `nil` included, as when `ls-remote` fails — git-lfs
    /// falls back to excluding every tip (`--not --remotes=<remote>`).
    ///
    /// An object absent from the local store fails the push with the
    /// `Git LFS upload failed:` block on stdout and status 2, unless
    /// `lfs.allowincompletepush` is true; then the block is headed
    /// `Git LFS upload missing objects:` and the present objects are uploaded.
    /// `dryRun` prints `push <oid> => <path>` lines and contacts no server.
    /// `terminal` says whether stdout is a terminal, for the progress meter.
    /// The meter's text is written to the shell's stdout as it is logged;
    /// the result holds everything else.
    /// Lock verification is not performed.
    public func uploadObjects(
        for updates: [LFSRefUpdate], remote: String = "", remoteBranches: [String]? = nil,
        dryRun: Bool = false, terminal: Bool = false, git: GitClient
    ) async throws -> LFSCommandResult {
        try await uploadObjects(for: updates, remote: remote, remoteBranches: remoteBranches, dryRun: dryRun,
                                terminal: terminal, git: git, environment: LFSTransferEnvironment())
    }

    func uploadObjects(
        for updates: [LFSRefUpdate], remote: String, remoteBranches: [String]?, dryRun: Bool, terminal: Bool,
        git: GitClient, environment: LFSTransferEnvironment
    ) async throws -> LFSCommandResult {
        let remote = remote.isEmpty ? finder.uploadRemote() : remote
        let store = try await LocalStore.open(git)
        let upload = LFSUploadContext(
            allowMissing: finder.configuration.boolean("lfs.allowincompletepush"),
            meter: await LFSProgressMeter.make(
                direction: .upload, display: !dryRun, terminal: terminal,
                configuration: finder.configuration, environment: environment))
        let updates = updates.filter { !LFSRefUpdate.isZero($0.localOID) }

        var exclude: [String] = []
        for update in updates where update.localOID != update.remoteOID {
            if !update.remoteOID.isEmpty, !LFSRefUpdate.isZero(update.remoteOID),
               try await git.canResolveRef(update.remoteOID) {
                exclude.append(update.remoteOID)
            }
        }
        exclude += try await Self.cachedRemoteExclusions(remote: remote, advertised: remoteBranches, git: git)

        var scanError: String?
        for update in updates {
            let pointers: [WrappedPointer]
            do {
                pointers = try await GitScanner(client: git).scanRefs(include: [update.localOID], exclude: exclude)
            } catch {
                scanError = "ref \(Self.refName(update.localRef).goQuoted):: \(error)"
                break
            }
            if dryRun {
                upload.dryRun(pointers)
                continue
            }
            var objects: [LFSBatchObject] = []
            var missing: Set<String> = []
            for pointer in upload.prepare(pointers) {
                let path = try await store.objectPath(pointer.pointer.oid)
                if !upload.allowMissing, !FileManager.default.fileExists(atPath: path.path) {
                    missing.insert(pointer.pointer.oid)
                }
                objects.append(LFSBatchObject(oid: pointer.pointer.oid, size: pointer.pointer.size,
                                              name: pointer.name, path: path.path))
            }
            let queue = LFSTransferQueue(
                client: self, store: store, direction: .upload, remote: remote,
                refName: update.remoteRef.isEmpty ? pushRemoteRef(update.localRef, remote: remote) : update.remoteRef,
                environment: environment, meter: upload.meter)
            upload.collect(try await queue.process(objects, missing: missing))
        }

        var result = upload.report()
        if result.status == 0, let scanError { result.fail(scanError) }
        return result
    }

    /// `calcSkippedRefs`: the cached `refs/remotes/<remote>/*` branch tips
    /// (`git.CachedRemoteRefs`, without `HEAD`) the remote still advertises;
    /// when there are none, every tip under the prefix (`--remotes=<remote>`).
    static func cachedRemoteExclusions(
        remote: String, advertised: [String]?, git: GitClient
    ) async throws -> [String] {
        let prefix = "refs/remotes/\(remote)/"
        let tips = try await git.references(matching: nil).filter { $0.name.hasPrefix(prefix) }
        let names = Set((advertised ?? []).map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 })
        let skipped = tips.filter { tip in
            let name = String(tip.name.dropFirst(prefix.count))
            return name != "HEAD" && names.contains(name)
        }
        return (skipped.isEmpty ? tips : skipped).map(\.targetSHA)
    }

    /// `git.ParseRef(...).Name`: a branch, tag or remote-tracking name
    /// without its `refs/…/` prefix.
    static func refName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/tags/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// `RefUpdate.RemoteRef().Refspec()` when the update names no remote
    /// ref (`defaultRemoteRef` under `push.default`).
    func pushRemoteRef(_ localRef: String, remote: String) -> String {
        let config = finder.configuration
        let name = Self.refName(localRef)
        func tracking() -> String { config.get("branch.\(name).merge") ?? localRef }
        switch config.get("push.default") ?? "" {
        case "", "simple":
            return config.get("branch.\(name).remote") == remote ? tracking() : localRef
        case "upstream", "tracking":
            return tracking()
        default:
            return localRef
        }
    }
}
