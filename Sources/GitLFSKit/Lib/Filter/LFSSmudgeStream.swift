import Foundation
import SwiftGit

final class LFSSmudgeStream: GitFilterStream {
    private let context: LFSFilterContext
    private let path: String
    private let output: (UnsafeRawBufferPointer) throws -> Void
    private var probe = Data()
    private var passthrough = false

    /// Internal regression probe: only a possible pointer is retained between writes.
    var bufferedByteCount: Int { probe.count }

    init(context: LFSFilterContext, path: String, output: @escaping (UnsafeRawBufferPointer) throws -> Void) {
        self.context = context
        self.path = path
        self.output = output
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        if passthrough { try output(chunk); return }
        let length = min(Pointer.blobSizeCutoff - probe.count, chunk.count)
        probe.append(contentsOf: chunk.prefix(length))
        if probe.count == Pointer.blobSizeCutoff {
            passthrough = true
            try probe.withUnsafeBytes(output)
            probe.removeAll()
            try output(UnsafeRawBufferPointer(rebasing: chunk.dropFirst(length)))
        }
    }

    func close() throws {
        guard !passthrough else { return }
        guard let pointer = try? Pointer.decode(probe) else {
            try probe.withUnsafeBytes(output)
            return
        }
        let configuration = context.configuration
        let filter = FilepathFilter(include: configuration.fetchPaths("lfs.fetchinclude"),
                                    exclude: configuration.fetchPaths("lfs.fetchexclude"))
        if context.skipSmudge || !filter.allows(path) {
            try Data(pointer.encoded.utf8).withUnsafeBytes(output)
            return
        }
        if pointer.size == 0 { return }
        let reader: FileHandle
        let first: Data
        do {
            let context = context
            let path = path
            let file = try context.run { try await context.smudgeFile(pointer, path: path) }
            let opened = try FileHandle(forReadingFrom: file)
            do {
                guard try opened.seekToEnd() == UInt64(pointer.size) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try opened.seek(toOffset: 0)
                first = try opened.read(upToCount: 64 * 1024) ?? Data()
            } catch {
                try? opened.close()
                throw error
            }
            reader = opened
        } catch {
            let failure = LFSFilterFailure(path: path, pointer: pointer, underlying: error,
                processCommand: context.processCommand, required: context.required)
            // Diagnostics use the captured Shell, including when suppressed.
            context.shell.stderr.write(Data((failure.localizedDescription + "\n").utf8))
            // Git's delayed checkout fails if filter-process exits, even for an optional driver.
            guard configuration.skipDownloadErrors || (!context.required && context.processCommand == nil)
            else { throw failure }
            let fallback = configuration.skipDownloadErrors ? Data(pointer.encoded.utf8) : probe
            try fallback.withUnsafeBytes(output)
            return
        }
        defer { try? reader.close() }
        // Neither file reads nor downstream writes after this point can replay
        // a pointer: some object bytes may already have reached the next filter.
        try first.withUnsafeBytes(output)
        while let data = try reader.read(upToCount: 64 * 1024), !data.isEmpty {
            try data.withUnsafeBytes(output)
        }
        try reader.close()
    }
}
