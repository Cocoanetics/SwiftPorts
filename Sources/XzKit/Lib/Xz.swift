// XzKit covers macOS / Linux / Windows via system liblzma, plus
// every Apple platform (incl. iOS / tvOS / watchOS / visionOS) via
// Apple's Compression.framework — `compression_encode_buffer` /
// `compression_decode_buffer` with `COMPRESSION_LZMA` accept and
// produce real `.xz` byte streams (verified against system `xz -d`).
// Android NDK ships none of these and isn't covered yet.
#if canImport(Compression) || os(Linux) || os(Windows)

import Foundation
import ShellKit
#if canImport(Compression)
import Compression
#else
import CLZMA
#endif

/// Pure-Swift `xz(1)` engine. On Apple platforms the backend is
/// libcompression; everywhere else it's liblzma's streaming API
/// (`lzma_easy_encoder` / `lzma_stream_decoder` + `lzma_code`).
/// Both backends emit and consume the same `.xz` container format.
public enum Xz {

    private static let chunkSize = 64 * 1024
    /// Encoder preset, 0..9. 6 is liblzma's default; matches `xz -6`.
    public static let defaultPreset: UInt32 = 6

    // MARK: Data

    /// Compress arbitrary bytes into an xz stream. Cooperatively
    /// cancellable: each output chunk checks `Task.isCancelled`.
    public static func compress(_ data: Data) async throws -> Data {
        #if canImport(Compression)
        return try appleCode(data, operation: COMPRESSION_STREAM_ENCODE,
                             algorithm: COMPRESSION_LZMA,
                             errorMap: XzKitError.compressionFailed)
        #else
        var stream = lzma_stream()
        let initResult = lzma_easy_encoder(
            &stream, defaultPreset, LZMA_CHECK_CRC64)
        guard initResult == LZMA_OK else {
            throw XzKitError.compressionFailed(
                "lzma_easy_encoder returned \(initResult.rawValue)")
        }
        defer { lzma_end(&stream) }
        return try driveLzmaStream(
            &stream, input: data, finishAction: LZMA_FINISH,
            errorMap: XzKitError.compressionFailed)
        #endif
    }

    /// Decompress an xz / lzma stream back to its raw bytes.
    /// Cooperatively cancellable: each output chunk checks
    /// `Task.isCancelled`.
    public static func decompress(_ data: Data) async throws -> Data {
        #if canImport(Compression)
        return try appleCode(data, operation: COMPRESSION_STREAM_DECODE,
                             algorithm: COMPRESSION_LZMA,
                             errorMap: XzKitError.decompressionFailed)
        #else
        var stream = lzma_stream()
        // memlimit = UINT64_MAX (no cap); flags = LZMA_CONCATENATED so
        // multi-stream files (`xz -F xz` default) decode end-to-end.
        // The macro expands to `UINT32_C(0x08)` which Swift's importer
        // doesn't surface — inline the literal.
        let lzmaConcatenated: UInt32 = 0x08
        let initResult = lzma_stream_decoder(
            &stream, UInt64.max, lzmaConcatenated)
        guard initResult == LZMA_OK else {
            throw XzKitError.decompressionFailed(
                "lzma_stream_decoder returned \(initResult.rawValue)")
        }
        defer { lzma_end(&stream) }
        return try driveLzmaStream(
            &stream, input: data, finishAction: LZMA_FINISH,
            errorMap: XzKitError.decompressionFailed)
        #endif
    }

    // MARK: Apple backend

    #if canImport(Compression)
    /// Drives `compression_stream` end-to-end. Both encode (with
    /// `.finalize` on the last call) and decode use the same loop.
    private static func appleCode(
        _ data: Data,
        operation: compression_stream_operation,
        algorithm: compression_algorithm,
        errorMap: (String) -> XzKitError
    ) throws -> Data {
        // `compression_stream_init` only inspects the `state` slot;
        // the other fields get overwritten before each
        // `compression_stream_process` call. Use a placeholder
        // pointer that doesn't own memory so we don't need a paired
        // `deallocate()` (the previous version allocated a 0-byte
        // buffer that was never freed — a small but real leak in
        // long-running processes).
        let placeholder = UnsafeMutablePointer<UInt8>(bitPattern: 1)!
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil)
        let initStatus = compression_stream_init(&stream, operation, algorithm)
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw errorMap("compression_stream_init returned \(initStatus.rawValue)")
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        return try data.withUnsafeBytes { rawIn -> Data in
            let inBase = rawIn.bindMemory(to: UInt8.self).baseAddress
            stream.src_ptr = inBase ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = data.count

            let finalize: Int32 = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

            var ended = false
            var madeProgress = true
            while !ended && madeProgress {
                try Task.checkCancellation()
                let inSizeBefore = stream.src_size
                try outputBuffer.withUnsafeMutableBufferPointer { outBuf in
                    stream.dst_ptr = outBuf.baseAddress!
                    stream.dst_size = chunkSize
                    let status = compression_stream_process(&stream, finalize)
                    let written = chunkSize - stream.dst_size
                    if written > 0 {
                        output.append(outBuf.baseAddress!, count: written)
                    }
                    switch status {
                    case COMPRESSION_STATUS_END:
                        ended = true
                    case COMPRESSION_STATUS_OK:
                        // Need to make progress to avoid spinning. If
                        // src didn't shrink AND dst stayed full, the
                        // stream is stuck — typical of truncated input.
                        madeProgress = (written > 0)
                            || (stream.src_size != inSizeBefore)
                    default:
                        throw errorMap(
                            "compression_stream_process returned \(status.rawValue)")
                    }
                }
            }
            if !ended {
                // Stream never produced END → input was incomplete.
                throw errorMap("incomplete xz stream (truncated input)")
            }
            return output
        }
    }
    #endif

    // MARK: liblzma backend

    #if !canImport(Compression)
    /// Drives the lzma stream loop end-to-end, used for both encode
    /// and decode (only the init / error mapping differ).
    private static func driveLzmaStream(
        _ stream: inout lzma_stream,
        input data: Data,
        finishAction: lzma_action,
        errorMap: (String) -> XzKitError
    ) throws -> Data {
        var output = Data()
        var inputBytes = [UInt8](data)
        let inputCount = inputBytes.count
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        try inputBytes.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = UnsafePointer(inPtr.baseAddress)
            stream.avail_in = inputCount

            var done = false
            while !done {
                try Task.checkCancellation()
                try outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = chunkSize
                    let r = lzma_code(&stream, finishAction)
                    let written = chunkSize - stream.avail_out
                    if written > 0 {
                        output.append(outPtr.baseAddress!, count: written)
                    }
                    switch r {
                    case LZMA_STREAM_END:
                        done = true
                    case LZMA_OK:
                        // No progress with no remaining input → truncated.
                        if written == 0 && stream.avail_in == 0 {
                            throw errorMap("incomplete xz stream (truncated input)")
                        }
                    default:
                        throw errorMap("lzma_code returned \(r.rawValue)")
                    }
                }
            }
        }
        return output
    }
    #endif

    // MARK: Files

    /// Compress `source` into a `.xz` file. Default destination is
    /// `source.xz`.
    @discardableResult
    public static func compressFile(
        at source: URL,
        to destination: URL? = nil,
        keepInput: Bool = false,
        overwrite: Bool = false
    ) async throws -> URL {
        let target = destination ?? URL(fileURLWithPath: source.path + ".xz")
        try await Shell.authorize(source)
        try await Shell.authorize(target)
        if FileManager.default.fileExists(atPath: target.path) && !overwrite {
            throw XzKitError.compressionFailed(
                "'\(Shell.displayPath(for: target))' already exists; pass overwrite: true to replace")
        }
        let bytes = try Data(contentsOf: source)
        let compressed = try await compress(bytes)
        try compressed.write(to: target)
        if !keepInput { try? FileManager.default.removeItem(at: source) }
        return target
    }

    /// Decompress an `.xz` file. Strips `.xz` (or `.txz` → `.tar`,
    /// `.lzma` → bare) when no destination is given.
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
            throw XzKitError.decompressionFailed(
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
        if path.hasSuffix(".xz") {
            return URL(fileURLWithPath: String(path.dropLast(3)))
        }
        if path.hasSuffix(".lzma") {
            return URL(fileURLWithPath: String(path.dropLast(5)))
        }
        if path.hasSuffix(".txz") {
            return URL(fileURLWithPath: String(path.dropLast(4)) + ".tar")
        }
        throw XzKitError.cannotInferOutputName(source)
    }
}

#endif // platform gate
