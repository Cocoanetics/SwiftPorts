// Lz4Kit — single-file LZ4 frame compression / decompression.
//
// Apple platforms (macOS / iOS / tvOS / watchOS / visionOS) use
// `Compression.framework`'s `COMPRESSION_LZ4_RAW` for block coding
// and we frame the output ourselves to produce standard `.lz4`
// v1.6.x output. Linux / Windows use `liblz4`'s low-level block
// API (`LZ4_compress_default` / `LZ4_decompress_safe`) wrapped in
// the same Swift framing layer, so output is byte-identical across
// backends.
//
// Android is gated out — NDK ships no liblz4 and Compression
// framework isn't there either. iOS / Linux / Windows / macOS get
// uniform coverage.

#if canImport(Compression) || os(Linux) || os(Windows)

import Foundation
import ShellKit
#if canImport(Compression)
import Compression
#else
import CLz4
#endif

public enum Lz4 {

    // MARK: Data

    /// Compress arbitrary bytes into an `.lz4` v1.6 frame. Splits
    /// input into 64 KB blocks (the spec's smallest tier); each
    /// block is independent, no checksums, so the frame is the
    /// minimum-overhead variant the spec allows. Cooperatively
    /// cancellable: each block boundary checks `Task.isCancelled`.
    public static func compress(_ data: Data) async throws -> Data {
        var blocks: [Lz4Frame.Block] = []
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = Swift.min(offset + Lz4Frame.blockSize, data.count)
            let chunk = Data(data[offset..<end])
            let compressed = try compressBlock(chunk)
            // Per .lz4 spec: if compressed size >= raw size, emit
            // the block uncompressed (high bit set in size word).
            if compressed.count >= chunk.count {
                blocks.append(.init(payload: chunk, uncompressed: true))
            } else {
                blocks.append(.init(payload: compressed, uncompressed: false))
            }
            offset = end
        }
        return Lz4Frame.build(blocks: blocks)
    }

    /// Decompress an `.lz4` v1.6 frame back to its raw bytes.
    /// Cooperatively cancellable: each block boundary checks
    /// `Task.isCancelled`.
    public static func decompress(_ data: Data) async throws -> Data {
        guard !data.isEmpty else {
            throw Lz4KitError.decompressionFailed(
                "incomplete lz4 stream (empty input)")
        }
        var output = Data()
        try await Lz4Frame.parseBlocks(data) { blockData, uncompressed in
            if uncompressed {
                output.append(blockData)
            } else {
                let decoded = try decompressBlock(
                    blockData, maxSize: Lz4Frame.blockSize)
                output.append(decoded)
            }
        }
        return output
    }

    // MARK: Files

    /// Compress `source` into `source.lz4` (or the explicit
    /// destination if given).
    @discardableResult
    public static func compressFile(
        at source: URL,
        to destination: URL? = nil,
        keepInput: Bool = false,
        overwrite: Bool = false
    ) async throws -> URL {
        let target = destination ?? URL(fileURLWithPath: source.path + ".lz4")
        try await Shell.authorize(source)
        try await Shell.authorize(target)
        if FileManager.default.fileExists(atPath: target.path) && !overwrite {
            throw Lz4KitError.compressionFailed(
                "'\(Shell.displayPath(for: target))' already exists; pass overwrite: true to replace")
        }
        let bytes = try Data(contentsOf: source)
        let compressed = try await compress(bytes)
        try compressed.write(to: target)
        if !keepInput { try? FileManager.default.removeItem(at: source) }
        return target
    }

    /// Decompress an `.lz4` file. Strips the `.lz4` (or `.tlz4`
    /// → `.tar`) suffix when no destination is given.
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
            throw Lz4KitError.decompressionFailed(
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
        if path.hasSuffix(".lz4") {
            return URL(fileURLWithPath: String(path.dropLast(4)))
        }
        if path.hasSuffix(".tlz4") {
            return URL(fileURLWithPath: String(path.dropLast(5)) + ".tar")
        }
        throw Lz4KitError.cannotInferOutputName(source)
    }

    // MARK: Backend block coding

    #if canImport(Compression)
    /// Compress one block via Apple's `compression_encode_buffer`
    /// with `COMPRESSION_LZ4_RAW`. Output is just the raw LZ4 block,
    /// no frame.
    private static func compressBlock(_ data: Data) throws -> Data {
        // LZ4 worst-case: srcSize + (srcSize / 255) + 16. Add a
        // little extra padding for tiny inputs.
        let bound = data.count + (data.count / 255) + 16 + 8
        var out = [UInt8](repeating: 0, count: bound)
        let n = data.withUnsafeBytes { rawIn -> Int in
            guard let inPtr = rawIn.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return out.withUnsafeMutableBufferPointer { outBuf in
                compression_encode_buffer(
                    outBuf.baseAddress!, bound,
                    inPtr, data.count,
                    nil, COMPRESSION_LZ4_RAW)
            }
        }
        if n == 0 {
            // Apple's `compression_encode_buffer` returns 0 when the
            // input is too small or too random for LZ4 to shrink.
            // The .lz4 frame format handles that natively — emit the
            // block uncompressed (high bit set in size word). We
            // signal "no savings" by returning the original Data; the
            // caller compares lengths and switches to the uncompressed
            // branch on equal-or-larger output.
            return data
        }
        return Data(out.prefix(n))
    }

    private static func decompressBlock(
        _ data: Data, maxSize: Int
    ) throws -> Data {
        if data.isEmpty { return Data() }
        var out = [UInt8](repeating: 0, count: maxSize)
        let n = data.withUnsafeBytes { rawIn -> Int in
            guard let inPtr = rawIn.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return out.withUnsafeMutableBufferPointer { outBuf in
                compression_decode_buffer(
                    outBuf.baseAddress!, maxSize,
                    inPtr, data.count,
                    nil, COMPRESSION_LZ4_RAW)
            }
        }
        if n == 0 {
            throw Lz4KitError.decompressionFailed(
                "compression_decode_buffer LZ4_RAW returned 0")
        }
        return Data(out.prefix(n))
    }
    #else
    /// Compress one block via liblz4's `LZ4_compress_default`.
    private static func compressBlock(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        let bound = LZ4_compressBound(Int32(data.count))
        guard bound > 0 else {
            throw Lz4KitError.compressionFailed(
                "LZ4_compressBound returned \(bound)")
        }
        var out = [UInt8](repeating: 0, count: Int(bound))
        let n: Int32 = data.withUnsafeBytes { rawIn in
            guard let inPtr = rawIn.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return out.withUnsafeMutableBufferPointer { outBuf in
                let inCharPtr = UnsafeRawPointer(inPtr)
                    .assumingMemoryBound(to: CChar.self)
                let outCharPtr = UnsafeMutableRawPointer(outBuf.baseAddress!)
                    .assumingMemoryBound(to: CChar.self)
                return LZ4_compress_default(
                    inCharPtr, outCharPtr,
                    Int32(data.count), bound)
            }
        }
        if n <= 0 {
            // liblz4 returns 0 if the destination buffer is too small.
            // With our generous bound that should never happen, but if
            // it does, fall back to uncompressed signaling — same
            // pattern as the Apple branch.
            return data
        }
        return Data(out.prefix(Int(n)))
    }

    private static func decompressBlock(
        _ data: Data, maxSize: Int
    ) throws -> Data {
        if data.isEmpty { return Data() }
        var out = [UInt8](repeating: 0, count: maxSize)
        let n: Int32 = data.withUnsafeBytes { rawIn in
            guard let inPtr = rawIn.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return out.withUnsafeMutableBufferPointer { outBuf in
                let inCharPtr = UnsafeRawPointer(inPtr)
                    .assumingMemoryBound(to: CChar.self)
                let outCharPtr = UnsafeMutableRawPointer(outBuf.baseAddress!)
                    .assumingMemoryBound(to: CChar.self)
                return LZ4_decompress_safe(
                    inCharPtr, outCharPtr,
                    Int32(data.count), Int32(maxSize))
            }
        }
        if n < 0 {
            throw Lz4KitError.decompressionFailed(
                "LZ4_decompress_safe returned \(n)")
        }
        return Data(out.prefix(Int(n)))
    }
    #endif
}

#endif // platform gate
