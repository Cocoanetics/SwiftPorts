import Foundation
import ShellKit

extension LFSFilterContext {
    func smudgeFile(_ pointer: Pointer, path: String) async throws -> URL {
        let file = store.objectPathname(pointer.oid)
        try await Shell.authorize(file)
        if LocalStore.isObject(at: file, size: pointer.size) { return file }
        let selected = if let remote = remotes.remote { remote } else { await client.finder.downloadRemote() }
        do {
            try await download(pointer, path: path, remote: selected)
            return try checkedFile(file, pointer: pointer)
        } catch {
            guard configuration.boolean("lfs.remote.searchall") else { throw error }
        }
        // gitfilter_smudge.go retries every configured remote, including the
        // selected one. Queue success ends that search even for a no-action batch;
        // read/check the object afterwards rather than treating it as downloaded.
        var last: any Error = LFSClientError("No known remotes")
        for remote in configuration.remotes {
            do { try await download(pointer, path: path, remote: remote) }
            catch { last = error; continue }
            remotes.remote = remote
            return try checkedFile(file, pointer: pointer)
        }
        throw last
    }

    private func download(_ pointer: Pointer, path: String, remote: String) async throws {
        let queue = LFSTransferQueue(client: client, store: store, direction: .download,
                                     remote: remote, refName: refName)
        do {
            try await queue.transfer([LFSBatchObject(oid: pointer.oid, size: pointer.size,
                                                    name: (path as NSString).lastPathComponent,
                                                    path: store.objectPathname(pointer.oid).path)])
        } catch {
            throw LFSClientError("Error downloading \(path) (\(pointer.oid)): \(error)")
        }
    }

    private func checkedFile(_ file: URL, pointer: Pointer) throws -> URL {
        guard LocalStore.isObject(at: file, size: pointer.size) else {
            // Reopen to preserve the original OS error for a missing object.
            do {
                let reader = try FileHandle(forReadingFrom: file)
                try reader.close()
            } catch {
                throw LFSClientError("error opening media file: " + lfsFileError(error, path: file.path))
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        return file
    }
}
