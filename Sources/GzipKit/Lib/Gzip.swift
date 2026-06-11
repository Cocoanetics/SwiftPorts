import Foundation
import CZlib
import ShellKit

/// Pure-Swift `gzip(1)` engine — single-file deflate/inflate via
/// zlib directly. Compresses with `MAX_WBITS + 16` (gzip framing);
/// decompresses with `MAX_WBITS + 32` so the same code accepts
/// either zlib-wrapped or gzip-wrapped streams transparently.
public enum Gzip {

    private static let chunkSize = 64 * 1024

    // MARK: Data

    /// Compress arbitrary bytes into a gzip stream. Cooperatively
    /// cancellable: each output chunk checks `Task.isCancelled`.
    public static func compress(_ data: Data) async throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,   // +16 → emit gzip framing
            8,                // memLevel — zlib's standard default
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw GzipKitError.compressionFailed(
                "deflateInit2 returned \(initResult)")
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        var inputBytes = [UInt8](data)
        let inputCount = inputBytes.count
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        try inputBytes.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inputCount)

            var done = false
            while !done {
                try Task.checkCancellation()
                try outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let r = deflate(&stream, Z_FINISH)
                    let written = chunkSize - Int(stream.avail_out)
                    if written > 0 {
                        output.append(outPtr.baseAddress!, count: written)
                    }
                    switch r {
                    case Z_STREAM_END: done = true
                    case Z_OK, Z_BUF_ERROR: break
                    default:
                        throw GzipKitError.compressionFailed(
                            "deflate returned \(r)")
                    }
                }
            }
        }
        return output
    }

    /// Decompress a gzip stream back to its raw bytes. Also accepts
    /// zlib-framed (RFC 1950) input — the +32 wbits auto-detects.
    /// Cooperatively cancellable: each output chunk checks
    /// `Task.isCancelled`.
    public static func decompress(_ data: Data) async throws -> Data {
        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            MAX_WBITS + 32,   // +32 → auto-detect gzip vs. zlib
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw GzipKitError.decompressionFailed(
                "inflateInit2 returned \(initResult)")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var inputBytes = [UInt8](data)
        let inputCount = inputBytes.count
        var outputBuffer = [UInt8](repeating: 0, count: chunkSize)

        try inputBytes.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inputCount)

            var done = false
            while !done {
                try Task.checkCancellation()
                try outputBuffer.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    let r = inflate(&stream, Z_NO_FLUSH)
                    let written = chunkSize - Int(stream.avail_out)
                    if written > 0 {
                        output.append(outPtr.baseAddress!, count: written)
                    }
                    switch r {
                    case Z_STREAM_END:
                        done = true
                    case Z_OK:
                        break
                    case Z_BUF_ERROR:
                        // Z_BUF_ERROR = inflate made no progress. We
                        // hand it the entire input upfront with a
                        // 64 KB output window each iteration, so the
                        // only realistic cause is starved input —
                        // i.e. the gzip stream is truncated. Treat
                        // as an error rather than silently returning
                        // partial bytes as if they were complete.
                        throw GzipKitError.decompressionFailed(
                            "incomplete gzip stream (truncated input)")
                    default:
                        throw GzipKitError.decompressionFailed(
                            "inflate returned \(r)")
                    }
                }
            }
        }
        return output
    }

    // MARK: Files

    /// Compress `source` into a gzip file. By default writes to
    /// `source.gz`; pass `destination` to override.
    @discardableResult
    public static func compressFile(
        at source: URL,
        to destination: URL? = nil,
        keepInput: Bool = false,
        overwrite: Bool = false
    ) async throws -> URL {
        let target = destination ?? URL(fileURLWithPath: source.path + ".gz")
        try await Shell.authorize(source)
        try await Shell.authorize(target)
        if FileManager.default.fileExists(atPath: target.path) && !overwrite {
            throw GzipKitError.compressionFailed(
                "'\(Shell.displayPath(for: target))' already exists; pass overwrite: true to replace")
        }
        let bytes = try Data(contentsOf: source)
        let compressed = try await compress(bytes)
        try compressed.write(to: target)
        if !keepInput { try? FileManager.default.removeItem(at: source) }
        return target
    }

    /// Decompress a gzip file. Infers the output name by stripping
    /// `.gz` (or `.tgz` / `.taz` → `.tar`, `.Z` → bare) when no
    /// destination is given.
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
            throw GzipKitError.decompressionFailed(
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
        if path.hasSuffix(".gz") {
            return URL(fileURLWithPath: String(path.dropLast(3)))
        }
        if path.hasSuffix(".tgz") {
            return URL(fileURLWithPath: String(path.dropLast(4)) + ".tar")
        }
        if path.hasSuffix(".taz") {
            return URL(fileURLWithPath: String(path.dropLast(4)) + ".tar")
        }
        if path.hasSuffix(".Z") {
            return URL(fileURLWithPath: String(path.dropLast(2)))
        }
        throw GzipKitError.cannotInferOutputName(source)
    }
}
