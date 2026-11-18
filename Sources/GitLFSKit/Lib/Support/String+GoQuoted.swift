import Foundation

extension String {
    /// The string as Go's `%q` prints it (`strconv.Quote`): in double
    /// quotes, with `"` and `\` escaped and control characters spelled out.
    var goQuoted: String {
        var quoted = "\""
        for scalar in unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\u{07}": quoted += "\\a"
            case "\u{08}": quoted += "\\b"
            case "\u{0C}": quoted += "\\f"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case "\u{0B}": quoted += "\\v"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    quoted += String(format: "\\x%02x", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }
}
