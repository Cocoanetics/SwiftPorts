import GitLFSTestSupport

/// Receipt and client completion race independently; retain their observation
/// times so delayed task-group delivery cannot reverse their causal order.
enum LFSUploadTimeoutEvent: Sendable {
    case receipt(LFSHeldObjectRequest)
    case completed(Result<Void, any Error>, at: ContinuousClock.Instant)
    case missingReceipt
    case deadline
}
