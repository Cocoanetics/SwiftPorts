import Foundation

/// The output and exit status of an upstream git-lfs command operation.
/// Kept independent of ArgumentParser so embedded callers use the same behavior.
public struct LFSCommandResult: Error, LocalizedError, Sendable {
    public var stdout = ""
    public var stderr = ""
    public var status: Int32 = 0

    public var errorDescription: String? { stderr.isEmpty ? stdout : stderr }

    public init(stdout: String = "", stderr: String = "", status: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
    }

    mutating func fail(_ message: String, status: Int32 = 2) {
        stderr += message + "\n"
        self.status = status
    }
}
