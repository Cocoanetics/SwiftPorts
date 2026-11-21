import Foundation
import HTTPTypes
import SwiftGit

/// `commands.lockVerifier`. A command owns this instance and mutates it only
/// during its serial ref scans and upload preparation, never on queue workers.
final class LFSLockVerifier: @unchecked Sendable {
    private let client: LFSClient
    private let git: GitClient
    private let remote: String
    private let endpoint: String
    private let state: Bool?
    private var verifiedRefs: Set<String> = []
    private var ours: [String: LFSRefLock] = [:]
    private var theirs: [String: LFSRefLock] = [:]
    private var owned: [String] = []
    private var unowned: [String] = []
    private(set) var stderr = ""

    init(client: LFSClient, remote: String, git: GitClient) {
        self.client = client
        self.git = git
        self.remote = remote
        endpoint = client.finder.endpoint(operation: "upload", remote: remote).url
        let config = client.finder.configuration
        if endpoint.hasPrefix("file://") || !(config.get("lfs.standalonetransferagent") ?? "").isEmpty {
            state = false
        } else if let configured = client.finder.urlConfig.get(prefix: "lfs", url: endpoint, key: "locksverify") {
            // getVerifyStateFor uses strconv.ParseBool, not Git's extended boolean vocabulary.
            state = ["1", "t", "T", "true", "TRUE", "True"].contains(configured)
        } else {
            let url = LFSURL.parse(endpoint)
            state = url.host == "github.com" && ["https", "ssh"].contains(url.scheme) ? true : nil
        }
    }

    func verify(_ updates: [LFSRefUpdate]) async throws {
        guard state != false else { return }
        for update in updates where !LFSRefUpdate.isZero(update.localOID) {
            let ref = update.remoteRef.isEmpty
                ? client.pushRemoteRef(update.localRef, remote: remote) : update.remoteRef
            guard !verifiedRefs.contains(ref) else { continue }
            do {
                try await search(ref: ref)
                if state == nil {
                    stderr += "Locking support detected on remote \(remote.goQuoted). Consider enabling it with:\n"
                    stderr += "  $ git config lfs.\(endpoint).locksverify true\n"
                }
            } catch {
                try Task.checkCancellation()
                let status = (error as? LFSClientError)?.transferResult?.status
                if status == 404 || status == 501 {
                    // As disableFor does, persist this for subsequent invocations.
                    try? await git.configSet("lfs.\(endpoint).locksverify", "false", scope: .local)
                } else if status == 401 || status == 403 {
                    let kind = state == true ? "error" : "warning"
                    stderr += "\(kind): Authentication error: \(error)\n"
                    if state == true { throw LFSFailure(String(stderr.dropLast())) }
                } else {
                    stderr += "Remote \(remote.goQuoted) does not support the Git LFS locking API. "
                        + "Consider disabling it with:\n"
                    stderr += "  $ git config lfs.\(endpoint).locksverify false\n"
                    if state == true { throw LFSFailure(stderr + String(describing: error)) }
                }
            }
            verifiedRefs.insert(ref)
        }
    }

    private func search(ref: String) async throws {
        try LFSClient.requireHTTP(LFSEndpoint(url: endpoint))
        let base = endpoint.hasSuffix("/") ? endpoint : endpoint + "/"
        guard let url = URL(string: base + "locks/verify") else { throw LFSClientError("invalid URL: \(base)") }
        var cursor = ""
        repeat {
            var payload = JSONText()
            payload.beginObject()
            payload.key("ref")
            payload.beginObject()
            if !ref.isEmpty { payload.key("name"); payload.string(ref) }
            payload.endObject()
            if !cursor.isEmpty { payload.key("cursor"); payload.string(cursor) }
            payload.endObject()
            var request = HTTPRequest(method: .post, url: url)
            request.headerFields[.accept] = LFSMediaType.json
            request.headerFields[.contentType] = LFSMediaType.requestContentType
            let (data, response) = try await client.send(request, body: .data(payload.data),
                                                        operation: "upload", remote: remote)
            let page = response.status.code == 200 ? try JSONDecoder().decode(LFSLockPage.self, from: data)
                : LFSLockPage()
            if let message = page.message, !message.isEmpty {
                throw LFSClientError("server error searching locks: \(message)")
            }
            for lock in page.ours ?? [] {
                ours[lock.path, default: LFSRefLock()].ownersByRef[ref] = lock.owner?.name ?? ""
            }
            for lock in page.theirs ?? [] {
                theirs[lock.path, default: LFSRefLock()].ownersByRef[ref] = lock.owner?.name ?? ""
            }
            cursor = page.nextCursor ?? ""
        } while !cursor.isEmpty
    }

    /// Non-LFS blobs are checked by the push scanner too.
    func foundNonPointer(_ name: String) { if theirs[name] != nil { unowned.append(name) } }

    func canUpload(_ name: String) -> Bool {
        if ours[name] != nil { owned.append(name) }
        guard theirs[name] != nil else { return true }
        unowned.append(name)
        return state != true
    }

    func report(into result: inout LFSCommandResult) {
        if !unowned.isEmpty {
            result.stdout += "Unable to push locked files:\n"
            for path in unowned {
                result.stdout += "* \(path) - \(theirs[path]?.owners(verifiedRefs: verifiedRefs) ?? "")\n"
            }
            if state == true { result.fail("Cannot update locked files.") }
            else { result.stderr += "warning: The above files would have halted this push.\n" }
        } else if !owned.isEmpty {
            result.stdout += "Consider unlocking your own locked files: (`git lfs unlock <path>`)\n"
            for path in owned { result.stdout += "* \(path)\n" }
        }
    }
}
