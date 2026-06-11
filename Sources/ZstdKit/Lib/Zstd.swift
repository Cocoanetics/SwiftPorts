// libbz2/liblzma/libzstd are not in the iOS / tvOS / watchOS / visionOS
// SDK. Gate the whole module to platforms where the system library is
// available; iOS support requires vendoring sources.
#if os(macOS) || os(Linux) || os(Windows)

import Foundation
import CZstd
import ShellKit

/// Pure-Swift `zstd(1)` engine — single-file compression / decompression
/// via libzstd's streaming API (`ZSTD_compressStream2` / `ZSTD_decompressStream`).
public enum Zstd {

    private static let chunkSize = 64 * 1024
    /// libzstd's standard default level — equivalent to `zstd -3`.
    public static let defaultLevel: Int32 = 3

    // MARK: Data

    /// Compress arbitrary bytes into a zstd frame. Cooperatively
    /// cancellable: each output chunk checks `Task.isCancelled`.
    public static func compress(_ data: Data) async throws -> Data {
        guard let cctx = ZSTD_createCCtx() else {
            throw ZstdKitError.compressionFailed("ZSTD_createCCtx returned NULL")
        }
        defer { ZSTD_freeCCtx(cctx) }
        let setLevel = ZSTD_CCtx_setParameter(
            cctx, ZSTD_c_compressionLevel, defaultLevel)
        if ZSTD_isError(setLevel) != 0 {
            throw ZstdKitError.compressionFailed(
                String(cString: ZSTD_getErrorName(setLevel)))
        }

        var output = Data()
        var inputBytes = [UInt8](data)
        let inputCount = inputBytes.count
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        try inputBytes.withUnsafeMutableBufferPointer { inPtr in
            var inBuf = ZSTD_inBuffer(
                src: UnsafeRawPointer(inPtr.baseAddress),
                size: inputCount,
                pos: 0)
            var done = false
            while !done {
                try Task.checkCancellation()
                try outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    var outBuf = ZSTD_outBuffer(
                        dst: UnsafeMutableRawPointer(outPtr.baseAddress),
                        size: chunkSize,
                        pos: 0)
                    let remaining = ZSTD_compressStream2(
                        cctx, &outBuf, &inBuf, ZSTD_e_end)
                    if ZSTD_isError(remaining) != 0 {
                        throw ZstdKitError.compressionFailed(
                            String(cString: ZSTD_getErrorName(remaining)))
                    }
                    if outBuf.pos > 0 {
                        output.append(outPtr.baseAddress!, count: outBuf.pos)
                    }
                    // ZSTD_e_end returns 0 once the frame is finalized.
                    if remaining == 0 { done = true }
                }
            }
        }
        return output
    }

    /// Decompress a zstd frame back to its raw bytes. Handles
    /// concatenated frames natively — zstd's streaming decoder loops
    /// across frame boundaries. Cooperatively cancellable: each
    /// output chunk checks `Task.isCancelled`.
    public static func decompress(_ data: Data) async throws -> Data {
        // Empty input is never a valid zstd stream — at minimum a
        // 4-byte magic + frame header + epilogue must be present.
        // Without this check the loop below would not iterate, leave
        // `lastResult` at zero, and we'd return Data() as if decoding
        // had succeeded, silently accepting truncated artifacts.
        guard !data.isEmpty else {
            throw ZstdKitError.decompressionFailed(
                "incomplete zstd stream (empty input)")
        }

        guard let dctx = ZSTD_createDCtx() else {
            throw ZstdKitError.decompressionFailed("ZSTD_createDCtx returned NULL")
        }
        defer { ZSTD_freeDCtx(dctx) }

        var output = Data()
        var inputBytes = [UInt8](data)
        let inputCount = inputBytes.count
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        try inputBytes.withUnsafeMutableBufferPointer { inPtr in
            var inBuf = ZSTD_inBuffer(
                src: UnsafeRawPointer(inPtr.baseAddress),
                size: inputCount,
                pos: 0)
            // Returns 0 when a frame is fully decoded. With concatenated
            // frames, the next call starts a fresh frame; loop until
            // both buffers are exhausted.
            var lastResult: size_t = 0
            while inBuf.pos < inBuf.size {
                try Task.checkCancellation()
                try outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    var outBuf = ZSTD_outBuffer(
                        dst: UnsafeMutableRawPointer(outPtr.baseAddress),
                        size: chunkSize,
                        pos: 0)
                    let r = ZSTD_decompressStream(dctx, &outBuf, &inBuf)
                    if ZSTD_isError(r) != 0 {
                        throw ZstdKitError.decompressionFailed(
                            String(cString: ZSTD_getErrorName(r)))
                    }
                    if outBuf.pos > 0 {
                        output.append(outPtr.baseAddress!, count: outBuf.pos)
                    }
                    lastResult = r
                }
            }
            // After the input is exhausted, lastResult == 0 means a
            // clean frame end. Non-zero means zstd is mid-frame and
            // expects more input — i.e. truncated.
            if lastResult != 0 {
                throw ZstdKitError.decompressionFailed(
                    "incomplete zstd stream (truncated input)")
            }
        }
        return output
    }

    // MARK: Files

    /// Compress `source` into a `.zst` file. Default destination is
    /// `source.zst`.
    @discardableResult
    public static func compressFile(
        at source: URL,
        to destination: URL? = nil,
        keepInput: Bool = false,
        overwrite: Bool = false
    ) async throws -> URL {
        let target = destination ?? URL(fileURLWithPath: source.path + ".zst")
        try await Shell.authorize(source)
        try await Shell.authorize(target)
        if FileManager.default.fileExists(atPath: target.path) && !overwrite {
            throw ZstdKitError.compressionFailed(
                "'\(Shell.displayPath(for: target))' already exists; pass overwrite: true to replace")
        }
        let bytes = try Data(contentsOf: source)
        let compressed = try await compress(bytes)
        try compressed.write(to: target)
        if !keepInput { try? FileManager.default.removeItem(at: source) }
        return target
    }

    /// Decompress a `.zst` file. Strips `.zst` (or `.tzst` → `.tar`)
    /// when no destination is given.
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
            throw ZstdKitError.decompressionFailed(
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
        if path.hasSuffix(".zst") {
            return URL(fileURLWithPath: String(path.dropLast(4)))
        }
        if path.hasSuffix(".tzst") {
            return URL(fileURLWithPath: String(path.dropLast(5)) + ".tar")
        }
        throw ZstdKitError.cannotInferOutputName(source)
    }
}

#endif // platform gate
