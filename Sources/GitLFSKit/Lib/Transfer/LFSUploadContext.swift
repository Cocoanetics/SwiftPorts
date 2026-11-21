/// `commands.uploadContext`: the OIDs already queued in this push, the
/// shared meter, and the queue errors `ReportErrors` prints.
final class LFSUploadContext {
    let allowMissing: Bool
    let meter: LFSProgressMeter
    private var uploaded: Set<String> = []
    private var stdout = ""
    /// Name → OID, in first-seen order (git-lfs keeps a map).
    private var missing: [(name: String, oid: String)] = []
    private var corrupt: [(name: String, oid: String)] = []
    private var otherErrors: [String] = []

    init(allowMissing: Bool, meter: LFSProgressMeter) {
        self.allowMissing = allowMissing
        self.meter = meter
    }

    /// `UploadPointers` under `--dry-run`.
    func dryRun(_ pointers: [WrappedPointer]) {
        for pointer in pointers where uploaded.insert(pointer.pointer.oid).inserted {
            stdout += "push \(pointer.pointer.oid) => \(pointer.name)\n"
        }
    }

    /// `prepareUpload`: each OID once per push, never the empty object,
    /// each counted by the meter.
    func prepare(_ pointers: [WrappedPointer]) -> [WrappedPointer] {
        var result: [WrappedPointer] = []
        for pointer in pointers where pointer.pointer.size != 0 && !uploaded.contains(pointer.pointer.oid) {
            uploaded.insert(pointer.pointer.oid)
            meter.add(pointer.pointer.size)
            result.append(pointer)
        }
        return result
    }

    /// `CollectErrors`.
    func collect(_ failures: [LFSTransferFailure]) {
        for failure in failures {
            switch failure {
            case .malformed(let name, let oid, let isMissing):
                if isMissing { Self.set(&missing, name, oid) } else { Self.set(&corrupt, name, oid) }
            case .message(let message):
                otherErrors.append(message)
            }
        }
    }

    private static func set(_ list: inout [(name: String, oid: String)], _ name: String, _ oid: String) {
        if let index = list.firstIndex(where: { $0.name == name }) { list[index].oid = oid }
        else { list.append((name, oid)) }
    }

    /// `ReportErrors`, without lock verification.
    func report() -> LFSCommandResult {
        meter.finish()
        var result = LFSCommandResult(stdout: stdout)
        for error in otherErrors { result.stderr += error + "\n" }
        if !missing.isEmpty || !corrupt.isEmpty {
            result.stdout += "Git LFS upload \(allowMissing ? "missing objects" : "failed"):\n"
            for entry in missing { result.stdout += "  (missing) \(entry.name) (\(entry.oid))\n" }
            for entry in corrupt { result.stdout += "  (corrupt) \(entry.name) (\(entry.oid))\n" }
            if !allowMissing {
                result.stdout += """
                hint: Your push was rejected due to missing or corrupt local objects.
                hint: You can disable this check with: `git config lfs.allowincompletepush true`

                """
                result.status = 2
                return result
            }
        }
        if !otherErrors.isEmpty { result.status = 2 }
        return result
    }
}
