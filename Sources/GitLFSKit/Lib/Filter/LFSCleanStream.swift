import Foundation
import Crypto
import SwiftGit

/// Only the pointer probe stays in memory. The temporary object also provides
/// replay for an optional driver when insertion fails before any output.
final class LFSCleanStream: GitFilterStream {
    private let context: LFSFilterContext
    private let output: (UnsafeRawBufferPointer) throws -> Void
    private let fileWrite: (FileHandle, Data) throws -> Void
    private let fileClose: (FileHandle) throws -> Void
    private var probe = Data()
    private var temporary: URL?
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var count: Int64 = 0
    private var passthrough = false

    /// Internal regression probe: content lives on disk after the pointer probe.
    var bufferedByteCount: Int { probe.count }

    init(
        context: LFSFilterContext,
        fileWrite: @escaping (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) },
        fileClose: @escaping (FileHandle) throws -> Void = { try $0.close() },
        output: @escaping (UnsafeRawBufferPointer) throws -> Void
    ) {
        self.context = context
        self.fileWrite = fileWrite
        self.fileClose = fileClose
        self.output = output
    }

    deinit { cleanup() }

    func write(_ chunk: UnsafeRawBufferPointer) throws {
        if passthrough { try output(chunk); return }
        var consumed = 0
        if temporary == nil {
            let probing = min(Pointer.blobSizeCutoff - probe.count, chunk.count)
            probe.append(contentsOf: chunk.prefix(probing))
            if probe.count < Pointer.blobSizeCutoff { return }
            consumed = probing
            do {
                let store = context.store
                let file = try context.run(onDiscard: { try? FileManager.default.removeItem(at: $0) }, {
                    try await store.makeTemporaryFile()
                })
                temporary = file
                handle = try FileHandle(forWritingTo: file)
                try append(probe)
            } catch {
                guard !context.required else { throw error }
                passthrough = true
                try probe.withUnsafeBytes(output)
                probe.removeAll()
                cleanup()
                try output(UnsafeRawBufferPointer(rebasing: chunk.dropFirst(probing)))
                return
            }
            probe.removeAll()
        }
        let rest = UnsafeRawBufferPointer(rebasing: chunk.dropFirst(consumed))
        // Once the temporary file exists, the entire next chunk is content.
        try appendOrReplay(rest)
    }

    private func append(_ data: Data) throws {
        if let handle { try fileWrite(handle, data) }
        hasher.update(data: data)
        count += Int64(data.count)
    }

    private func appendOrReplay(_ chunk: UnsafeRawBufferPointer) throws {
        // Bound copies even when the caller lends one very large chunk.
        var offset = 0
        while offset < chunk.count {
            let end = min(offset + 64 * 1024, chunk.count)
            do { try append(Data(chunk[offset..<end])) }
            catch {
                guard !context.required else { throw error }
                passthrough = true
                try replay()
                try output(UnsafeRawBufferPointer(rebasing: chunk[offset...]))
                cleanup()
                return
            }
            offset = end
        }
    }

    func close() throws {
        defer { cleanup() }
        guard !passthrough else { return }
        if temporary == nil {
            if (try? Pointer.decode(probe)) != nil {
                try probe.withUnsafeBytes(output)
                return
            }
            do {
                let store = context.store
                temporary = try context.run(onDiscard: { try? FileManager.default.removeItem(at: $0) }, {
                    try await store.makeTemporaryFile()
                })
                handle = try FileHandle(forWritingTo: temporary!)
                try append(probe)
            } catch {
                guard !context.required else { throw error }
                try probe.withUnsafeBytes(output)
                return
            }
            probe.removeAll()
        }
        let pointer: Pointer
        do {
            if let handle { try fileClose(handle) }
            handle = nil
            let oid = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let file = temporary!
            let store = context.store
            _ = try context.run { try await store.insert(temporaryFile: file, oid: oid) }
            temporary = nil
            pointer = Pointer(oid: oid, size: count)
        } catch {
            guard !context.required else { throw error }
            try replay()
            return
        }
        // Output errors are never transform failures: no fallback after output.
        try Data(pointer.encoded.utf8).withUnsafeBytes(output)
    }

    private func replay() throws {
        guard let temporary else { return }
        let reader = try FileHandle(forReadingFrom: temporary)
        defer { try? reader.close() }
        var remaining = count
        while remaining > 0, let data = try reader.read(upToCount: Int(min(remaining, 64 * 1024))), !data.isEmpty {
            try data.withUnsafeBytes(output)
            remaining -= Int64(data.count)
        }
        if remaining != 0 { throw CocoaError(.fileReadCorruptFile) }
    }

    private func cleanup() {
        try? handle?.close()
        handle = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        temporary = nil
    }
}
