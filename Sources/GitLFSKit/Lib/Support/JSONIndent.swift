/// `encoding/json.Indent` with an empty prefix, as `Encoder.SetIndent` applies
/// it to compact output: empty objects and arrays stay `{}` and `[]`.
enum JSONIndent {
    static func indent(_ compact: String, by unit: String) -> String {
        var output = ""
        var depth = 0
        var needIndent = false
        var inString = false
        var escaped = false
        func newline() {
            output.append("\n")
            output.append(String(repeating: unit, count: depth))
        }
        for character in compact {
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if needIndent, character != "]", character != "}" {
                needIndent = false
                depth += 1
                newline()
            }
            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                needIndent = true
            case ",":
                output.append(character)
                newline()
            case ":":
                output.append(": ")
            case "}", "]":
                if needIndent {
                    needIndent = false
                } else {
                    depth -= 1
                    newline()
                }
                output.append(character)
            default:
                output.append(character)
            }
        }
        return output
    }
}
