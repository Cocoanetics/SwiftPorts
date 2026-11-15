import Foundation

/// RFC 4251 strings and positive mpints, shared by key files and SSHSIG.
struct SSHWireWriter {
    var bytes: [UInt8] = []

    mutating func uint32(_ value: UInt32) {
        bytes += [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    mutating func string(_ value: some Collection<UInt8>) {
        uint32(UInt32(value.count))
        bytes += value
    }

    mutating func string(_ value: String) { string(value.utf8) }

    mutating func mpint(_ value: some Collection<UInt8>) {
        var magnitude = Array(value.drop(while: { $0 == 0 }))
        if let first = magnitude.first, first & 0x80 != 0 { magnitude.insert(0, at: 0) }
        string(magnitude)
    }
}
