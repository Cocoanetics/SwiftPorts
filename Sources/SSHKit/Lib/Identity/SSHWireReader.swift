import Foundation

/// A minimal reader for the SSH binary wire format (RFC 4251 §5) used both by the
/// `openssh-key-v1` private-key container (`PROTOCOL.key`) and the per-key-type blobs within it
/// (`PROTOCOL.agent`'s key encoding, reused verbatim by `PROTOCOL.key` §3). Kept separate from
/// `NIOSSH`'s own `ByteBuffer` wire-format helpers because those are `internal` to the `NIOSSH`
/// module and not visible here.
struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, self.offset + count <= self.bytes.count else {
            throw SSHWireReaderError.truncated
        }
        defer { self.offset += count }
        return Array(self.bytes[self.offset..<(self.offset + count)])
    }

    mutating func readUInt32() throws -> UInt32 {
        let b = try self.readBytes(4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    /// An SSH "string": a `uint32` length prefix followed by that many raw bytes.
    mutating func readString() throws -> [UInt8] {
        let length = try self.readUInt32()
        return try self.readBytes(Int(length))
    }

    mutating func readUTF8String() throws -> String {
        guard let string = String(bytes: try self.readString(), encoding: .utf8) else {
            throw SSHWireReaderError.invalidUTF8
        }
        return string
    }

    /// An SSH "mpint" (RFC 4251 §5): wire-identical to a string, but the byte content is a
    /// two's-complement big-endian integer with a leading `0x00` inserted whenever the high bit
    /// of the first byte would otherwise be set on a non-negative value. This port only reads
    /// non-negative EC private scalars, so a leading `0x00` is simply dropped.
    mutating func readMPIntMagnitude() throws -> [UInt8] {
        var value = try self.readString()
        if value.first == 0 {
            value.removeFirst()
        }
        return value
    }
}
