/// `encoding/json.Indent` with an empty prefix, as `Encoder.SetIndent` applies
/// it to compact output: empty objects and arrays stay `{}` and `[]`. The
/// syntax is ASCII, so it is read byte by byte; a combining mark next to a
/// quote or comma cannot hide it, as it would in a `Character`.
enum JSONIndent {
    static func indent(_ compact: String, by unit: String) -> String {
        let unit = Array(unit.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(compact.utf8.count * 2)
        var depth = 0
        var needIndent = false
        var inString = false
        var escaped = false
        func newline() {
            output.append(UInt8(ascii: "\n"))
            for _ in 0..<depth { output += unit }
        }
        for byte in compact.utf8 {
            if inString {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            if needIndent, byte != UInt8(ascii: "]"), byte != UInt8(ascii: "}") {
                needIndent = false
                depth += 1
                newline()
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                output.append(byte)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                output.append(byte)
                needIndent = true
            case UInt8(ascii: ","):
                output.append(byte)
                newline()
            case UInt8(ascii: ":"):
                output += [UInt8(ascii: ":"), UInt8(ascii: " ")]
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if needIndent {
                    needIndent = false
                } else {
                    depth -= 1
                    newline()
                }
                output.append(byte)
            default:
                output.append(byte)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
