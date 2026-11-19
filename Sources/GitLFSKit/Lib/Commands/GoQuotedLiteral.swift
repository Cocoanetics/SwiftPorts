import Foundation

/// `strconv.Unquote` for a double-quoted Go string, which is what git-lfs uses
/// for a quoted `.gitattributes` pattern. Octal (`\303\251`), `\x`, `\u`, and
/// `\U` are accepted; JSON decoding is not.
enum GoQuotedLiteral {
    struct Failure: Error {}

    static func unquote(_ literal: String) throws -> String {
        let raw = Array(literal.utf8)
        guard raw.count >= 2, raw[0] == 0x22, raw[raw.count - 1] == 0x22 else { throw Failure() }
        let bytes = Array(raw[1..<(raw.count - 1)])
        if bytes.contains(0x0A) || bytes.contains(0x0D) { throw Failure() }
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte != 0x5C {
                output.append(byte)
                index += 1
                continue
            }
            let next = index + 1
            guard next < bytes.count else { throw Failure() }
            switch bytes[next] {
            case 0x61: output.append(0x07); index = next + 1
            case 0x62: output.append(0x08); index = next + 1
            case 0x66: output.append(0x0C); index = next + 1
            case 0x6E: output.append(0x0A); index = next + 1
            case 0x72: output.append(0x0D); index = next + 1
            case 0x74: output.append(0x09); index = next + 1
            case 0x76: output.append(0x0B); index = next + 1
            case 0x5C, 0x22: output.append(bytes[next]); index = next + 1
            case 0x78:
                index = next + 1
                output.append(try hexByte(bytes, &index, digits: 2))
            case 0x75:
                index = next + 1
                try appendScalar(hexValue(bytes, &index, digits: 4), to: &output)
            case 0x55:
                index = next + 1
                try appendScalar(hexValue(bytes, &index, digits: 8), to: &output)
            case 0x30...0x37:
                index = next
                output.append(try octalByte(bytes, &index))
            default:
                throw Failure()
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func octalByte(_ bytes: [UInt8], _ index: inout Int) throws -> UInt8 {
        guard index + 2 < bytes.count else { throw Failure() }
        var value = 0
        for _ in 0..<3 {
            let digit = bytes[index]
            guard (0x30...0x37).contains(digit) else { throw Failure() }
            value = value * 8 + Int(digit - 0x30)
            index += 1
        }
        guard value <= 255 else { throw Failure() }
        return UInt8(value)
    }

    private static func hexByte(_ bytes: [UInt8], _ index: inout Int, digits: Int) throws -> UInt8 {
        UInt8(try hexValue(bytes, &index, digits: digits))
    }

    private static func hexValue(_ bytes: [UInt8], _ index: inout Int, digits: Int) throws -> Int {
        guard index + digits <= bytes.count else { throw Failure() }
        var value = 0
        for _ in 0..<digits {
            let digit = bytes[index]
            let parsed: Int
            switch digit {
            case 0x30...0x39: parsed = Int(digit - 0x30)
            case 0x61...0x66: parsed = Int(digit - 0x61) + 10
            case 0x41...0x46: parsed = Int(digit - 0x41) + 10
            default: throw Failure()
            }
            value = value * 16 + parsed
            index += 1
        }
        return value
    }

    private static func appendScalar(_ value: Int, to output: inout [UInt8]) throws {
        guard value <= 0x10FFFF, let scalar = Unicode.Scalar(value) else { throw Failure() }
        output.append(contentsOf: String(scalar).utf8)
    }
}
