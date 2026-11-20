/// Why the transfer queue is done with an OID: its transfer finished (or, in
/// a dry run, would have), or the batch response gave it no action for the
/// queue's direction, so there was nothing to transfer.
enum LFSTransferCompletion: Sendable, Equatable {
    case transferred(LFSBatchObject)
    case skipped(LFSBatchObject)
}
