import Foundation

/// `fetchWatcher`: under `--json` it keeps every transferred object for
/// `dumpJson`; under `--dry-run` it prints `fetch <oid> => <name>` and
/// remembers the OID so a later ref does not list it again.
final class LFSFetchWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let json: Bool
    private let dryRun: Bool
    private var transfers: [LFSBatchObject] = []
    private var observed: Set<String> = []
    private var progress = ""

    init(json: Bool, dryRun: Bool) {
        self.json = json
        self.dryRun = dryRun
    }

    /// `registerTransfer`, once per pointer that shares a finished OID.
    func register(_ transfer: LFSBatchObject) {
        lock.withLock {
            if json { transfers.append(transfer) }
            if dryRun {
                observed.insert(transfer.oid)
                progress += "fetch \(transfer.oid) => \(transfer.name)\n"
            }
        }
    }

    func hasObserved(_ oid: String) -> Bool {
        lock.withLock { observed.contains(oid) }
    }

    /// The `fetch … => …` lines registered so far, which are then cleared.
    func drainProgress() -> String {
        lock.withLock {
            defer { progress = "" }
            return progress
        }
    }

    /// `dumpJson`: `{"transfers": […]}` indented by one space, with a final newline.
    func dumpJSON() -> String {
        let transfers = lock.withLock { self.transfers }
        var json = JSONText()
        json.beginObject()
        json.key("transfers")
        json.beginArray()
        for transfer in transfers { Self.write(transfer, into: &json) }
        json.endArray()
        json.endObject()
        return JSONIndent.indent(String(decoding: json.data, as: UTF8.self), by: " ") + "\n"
    }

    /// `tq.Transfer` as the watcher sees it: no `authenticated` or `error`.
    private static func write(_ transfer: LFSBatchObject, into json: inout JSONText) {
        json.beginObject()
        if !transfer.name.isEmpty {
            json.key("name")
            json.string(transfer.name)
        }
        if !transfer.oid.isEmpty {
            json.key("oid")
            json.string(transfer.oid)
        }
        json.key("size")
        json.number(transfer.size)
        if !transfer.actions.isEmpty { write(transfer.actions, key: "actions", into: &json) }
        if !transfer.links.isEmpty { write(transfer.links, key: "_links", into: &json) }
        if !transfer.path.isEmpty {
            json.key("path")
            json.string(transfer.path)
        }
        json.endObject()
    }

    /// `tq.Action`: `expires_at` is a `time.Time`, which `omitempty` never
    /// omits, so an action without one shows Go's zero time.
    private static func write(_ actions: [String: LFSBatchAction], key: String, into json: inout JSONText) {
        json.key(key)
        json.beginObject()
        for name in actions.keys.sorted() {
            guard let action = actions[name] else { continue }
            json.key(name)
            json.beginObject()
            json.key("href")
            json.string(action.href)
            if !action.header.isEmpty {
                json.key("header")
                json.beginObject()
                for field in action.header.keys.sorted() {
                    json.key(field)
                    json.string(action.header[field] ?? "")
                }
                json.endObject()
            }
            json.key("expires_at")
            if let expiresAt = action.expiresAt, !LFSTimestamp.isGoZero(expiresAt) {
                json.string(LFSTimestamp.string(from: expiresAt))
            } else {
                json.string("0001-01-01T00:00:00Z")
            }
            if action.expiresIn != 0 {
                json.key("expires_in")
                json.number(Int64(action.expiresIn))
            }
            json.endObject()
        }
        json.endObject()
    }
}
