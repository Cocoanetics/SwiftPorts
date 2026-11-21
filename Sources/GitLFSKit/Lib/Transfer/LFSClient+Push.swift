import Foundation
import ShellKit
import SwiftGit

extension LFSClient {
    /// `git.ResolveRef`: preserve the full ref name for fetch banners and batch ref metadata.
    func commandRef(_ name: String, git: GitClient) async throws -> String {
        guard let oid = try? await git.resolveOID(name) else {
            throw LFSFailure("Git can't resolve ref: \(name.goQuoted)")
        }
        if name == "HEAD" {
            let current = await Self.currentRef(git)
            return current == "HEAD" ? oid : current
        }
        let refs = try await git.references(matching: nil)
        for candidate in [name, "refs/" + name, "refs/tags/" + name, "refs/heads/" + name, "refs/remotes/" + name]
        where refs.contains(where: { $0.name == candidate }) {
            return candidate
        }
        return oid
    }

    /// `uploadsWithObjectIDs`: use media paths and sizes directly, without scanning Git objects.
    func pushObjectIDs(
        _ oids: [String], remote: String, dryRun: Bool, terminal: Bool, git: GitClient
    ) async throws -> LFSCommandResult {
        let store = try await LocalStore.open(git)
        var pointers: [WrappedPointer] = []
        for oid in oids {
            let path: URL
            do { path = try await store.objectPath(oid) }
            catch { throw LFSFailure("Unable to find local media path:: \(error)") }
            try await Shell.authorize(path)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: path.path) }
            catch {
                throw LFSFailure("Unable to stat local media path: "
                    + lfsFileError(error, path: path.path, operation: "stat"))
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            pointers.append(WrappedPointer(pointer: Pointer(oid: oid, size: size), oid: "", name: path.path))
        }
        let environment = LFSTransferEnvironment()
        let upload = LFSUploadContext(
            allowMissing: finder.configuration.boolean("lfs.allowincompletepush"),
            meter: await LFSProgressMeter.make(direction: .upload, display: !dryRun, terminal: terminal,
                                              configuration: finder.configuration, environment: environment))
        if dryRun { upload.dryRun(pointers) } else {
            let objects = upload.prepare(pointers).map {
                LFSBatchObject(oid: $0.pointer.oid, size: $0.pointer.size, name: $0.name, path: $0.name)
            }
            let ref = pushRemoteRef(await Self.currentRef(git), remote: remote)
            let queue = LFSTransferQueue(client: self, store: store, direction: .upload, remote: remote,
                                         refName: ref, environment: environment, meter: upload.meter)
            upload.collect(try await queue.process(objects))
        }
        return upload.report()
    }
}
