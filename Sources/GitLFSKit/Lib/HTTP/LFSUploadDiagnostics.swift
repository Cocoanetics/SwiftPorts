#if os(Windows)
/// Temporary CI probe, opted into by tests only. No process output or public
/// diagnostic mode; the callback is captured before entering the curl worker.
enum LFSUploadDiagnostics {
    @TaskLocal static var sink: (@Sendable (String) -> Void)?
}
#endif
