struct LFSFailure: Error {
    let result: LFSCommandResult

    init(_ message: String, status: Int32 = 2, stdout: Bool = false) {
        result = LFSCommandResult(
            stdout: stdout ? message + "\n" : "",
            stderr: stdout ? "" : message + "\n", status: status)
    }
}
