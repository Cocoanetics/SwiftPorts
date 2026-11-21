import SwiftGit

/// Input is borrowed only within write; output stays on the callback thread.
final class LFSPassthroughStream: GitFilterStream {
    private let output: GitFilterOutput

    init(output: GitFilterOutput) { self.output = output }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        try output.write(chunk)
    }

    func close() throws {}
}
