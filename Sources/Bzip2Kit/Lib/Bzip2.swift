// libbz2 isn't in the iOS / tvOS / watchOS / visionOS SDK — gate the
// whole module to platforms where the system library is available.
// To support Apple-mobile we'd need to vendor the libbz2 sources (a
// few thousand lines of MIT-licensed C); not worth the complexity
// until a concrete consumer needs it.
#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import CBzip2
import ShellKit

/// Pure-Swift `bzip2(1)` engine — single-file compression / decompression
/// via libbz2's streaming API (`BZ2_bzCompress*` / `BZ2_bzDecompress*`).
public enum Bzip2 {

    private static let chunkSize = 64 * 1024
    /// Block size in 100KB units. Upstream bzip2 defaults to 9 (best);
    /// matches `bzip2 -9`. Lower values trade ratio for memory.
    public static let defaultBlockSize: Int32 = 9

    // MARK: Data

    /// Compress arbitrary bytes into a bzip2 stream. Cooperatively
    /// cancellable: each output chunk checks `Task.isCancelled`.
    public static func compress(_ data: Data) async throws -> Data {
        var stream = bz_stream()
        let initResult = BZ2_bzCompressInit(
            &stream, defaultBlockSize, /*verbosity*/ 0, /*workFactor*/ 0)
        guard initResult == BZ_OK else {
            throw Bzip2KitError.compressionFailed(
                "BZ2_bzCompressInit returned \(initResult)")
        }
        defer { BZ2_bzCompressEnd(&stream) }

        var output = Data()
        var inputBytes = [UInt8](data)
        let inputCount = inputBytes.count
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        try inputBytes.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress.map { reinterpretAsCChar($0) }
            stream.avail_in = UInt32(inputCount)

            var done = false
            while !done {
                try Task.checkCancellation()
                try outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress.map { reinterpretAsCChar($0) }
                    stream.avail_out = UInt32(chunkSize)
                    let r = BZ2_bzCompress(&stream, BZ_FINISH)
                    let written = chunkSize - Int(stream.avail_out)
                    if written > 0 {
                        output.append(outPtr.baseAddress!, count: written)
                    }
                    switch r {
                    case BZ_STREAM_END:
                        done = true
                    case BZ_FINISH_OK, BZ_RUN_OK, BZ_FLUSH_OK:
                        break
                    default:
                        throw Bzip2KitError.compressionFailed(
                            "BZ2_bzCompress returned \(r)")
                    }
                }
            }
        }
        return output
    }

    /// Decompress a bzip2 stream back to its raw bytes. Cooperatively
    /// cancellable: each output chunk checks `Task.isCancelled`.
    public static func decompress(_ data: Data) async throws -> Data {
        var stream = bz_stream()
        let initResult = BZ2_bzDecompressInit(
            &stream, /*verbosity*/ 0, /*small*/ 0)
        guard initResult == BZ_OK else {
            throw Bzip2KitError.decompressionFailed(
                "BZ2_bzDecompressInit returned \(initResult)")
        }
        defer { BZ2_bzDecompressEnd(&stream) }

        var output = Data()
        var inputBytes = [UInt8](data)
        let inputCount = inputBytes.count
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        try inputBytes.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress.map { reinterpretAsCChar($0) }
            stream.avail_in = UInt32(inputCount)

            var done = false
            while !done {
                try Task.checkCancellation()
                try outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress.map { reinterpretAsCChar($0) }
                    stream.avail_out = UInt32(chunkSize)
                    let r = BZ2_bzDecompress(&stream)
                    let written = chunkSize - Int(stream.avail_out)
                    if written > 0 {
                        output.append(outPtr.baseAddress!, count: written)
                    }
                    switch r {
                    case BZ_STREAM_END:
                        done = true
                    case BZ_OK:
                        // No progress on either side = truncated.
                        if written == 0 && stream.avail_in == 0 {
                            throw Bzip2KitError.decompressionFailed(
                                "incomplete bzip2 stream (truncated input)")
                        }
                    default:
                        throw Bzip2KitError.decompressionFailed(
                            "BZ2_bzDecompress returned \(r)")
                    }
                }
            }
        }
        return output
    }

    // MARK: Files

    /// Compress `source` into a `.bz2` file. Default destination is
    /// `source.bz2`.
    @discardableResult
    public static func compressFile(
        at source: URL,
        to destination: URL? = nil,
        keepInput: Bool = false,
        overwrite: Bool = false
    ) async throws -> URL {
        let target = destination ?? URL(fileURLWithPath: source.path + ".bz2")
        try await Shell.authorize(source)
        try await Shell.authorize(target)
        if FileManager.default.fileExists(atPath: target.path) && !overwrite {
            throw Bzip2KitError.compressionFailed(
                "'\(Shell.displayPath(for: target))' already exists; pass overwrite: true to replace")
        }
        let bytes = try Data(contentsOf: source)
        let compressed = try await compress(bytes)
        try compressed.write(to: target)
        if !keepInput { try? FileManager.default.removeItem(at: source) }
        return target
    }

    /// Decompress a `.bz2` file. Strips `.bz2` (or `.tbz` / `.tbz2`
    /// → `.tar`) when no destination is given.
    @discardableResult
    public static func decompressFile(
        at source: URL,
        to destination: URL? = nil,
        keepInput: Bool = false,
        overwrite: Bool = false
    ) async throws -> URL {
        let target: URL
        if let destination {
            target = destination
        } else {
            target = try inferDecompressedName(from: source)
        }
        try await Shell.authorize(source)
        try await Shell.authorize(target)
        if FileManager.default.fileExists(atPath: target.path) && !overwrite {
            throw Bzip2KitError.decompressionFailed(
                "'\(Shell.displayPath(for: target))' already exists; pass overwrite: true to replace")
        }
        let bytes = try Data(contentsOf: source)
        let decompressed = try await decompress(bytes)
        try decompressed.write(to: target)
        if !keepInput { try? FileManager.default.removeItem(at: source) }
        return target
    }

    private static func inferDecompressedName(from source: URL) throws -> URL {
        let path = source.path
        if path.hasSuffix(".bz2") {
            return URL(fileURLWithPath: String(path.dropLast(4)))
        }
        if path.hasSuffix(".tbz2") {
            return URL(fileURLWithPath: String(path.dropLast(5)) + ".tar")
        }
        if path.hasSuffix(".tbz") {
            return URL(fileURLWithPath: String(path.dropLast(4)) + ".tar")
        }
        throw Bzip2KitError.cannotInferOutputName(source)
    }
}

/// libbz2's `bz_stream.next_in` / `next_out` are `char*` (CChar). Our
/// buffers are `[UInt8]`. Both are 1-byte; the pointer cast is a
/// pure type reinterpretation — safe because we're not punning the
/// underlying values, just naming them.
@inline(__always)
private func reinterpretAsCChar(
    _ p: UnsafeMutablePointer<UInt8>
) -> UnsafeMutablePointer<CChar> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
}

#endif // platform gate
