import SwiftGit

extension StatusOptions {
    /// `CurrentRef` tolerates an unborn HEAD. A detached HEAD resolves as `HEAD`.
    func renderTracking(client: GitClient, output: inout String) async throws {
        guard let head = try? await client.resolveOID("HEAD") else { return }
        let branch = try? await client.currentBranch()
        output += "On branch \(branch ?? "HEAD")\n"
        guard let branch, let tracking = try? await trackingRef(branch: branch, client: client) else { return }
        output += "Objects to be pushed to \(tracking.name):\n\n"
        var pointers: [WrappedPointer] = []
        defer {
            for pointer in pointers {
                output += "\t\(pointer.name) (\(pointer.pointer.oid))\n"
            }
        }
        do {
            try await GitScanner(client: client).scanRefs(include: [head], exclude: [tracking.oid], into: &pointers)
        } catch {
            throw LFSFailure("Could not scan for Git LFS objects: \(error.localizedDescription)")
        }
    }

    /// `RemoteRefNameForCurrentBranch`: only the fetch tracking configuration participates.
    func trackingRef(branch: String, client: GitClient) async throws -> (name: String, oid: String)? {
        guard let remote = try await client.configGet("branch.\(branch).remote"), !remote.isEmpty else { return nil }
        let merge = try await client.configGet("branch.\(branch).merge") ?? ""
        let trackingBranch = merge.hasPrefix("refs/heads/") ? String(merge.dropFirst(11)) : branch
        let name = "\(remote)/\(trackingBranch)"
        let ref = "refs/remotes/" + name
        guard try await client.canResolveRef(ref) else { return nil }
        return (name, try await client.resolveOID(ref))
    }
}
