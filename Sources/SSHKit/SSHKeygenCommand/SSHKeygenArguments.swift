import SSHKit

struct SSHKeygenArguments {
    var values: [Character: String] = [:]
    var flags: Set<Character> = []
    var options: [String] = []
    var files: [String] = []

    subscript(_ flag: Character) -> String? { values[flag] }

    static func parse(_ argv: [String]) throws -> Self {
        var result = Self()
        var index = 0
        while index < argv.count {
            let arg = argv[index]
            if arg == "--" { index += 1; break }
            if !arg.hasPrefix("-") || arg == "-" { break }
            let chars = Array(arg.dropFirst())
            var offset = 0
            while offset < chars.count {
                let flag = chars[offset]
                if "qUyl".contains(flag) { result.flags.insert(flag); offset += 1; continue }
                guard "YnfIsrOtbfNC".contains(flag) else {
                    throw SSHKeygenError("unknown option -- \(flag)")
                }
                let value: String
                if offset + 1 < chars.count { value = String(chars[(offset + 1)...]) }
                else {
                    index += 1
                    guard index < argv.count else { throw SSHKeygenError("option requires an argument -- \(flag)") }
                    value = argv[index]
                }
                if flag == "O" { result.options.append(value) } else { result.values[flag] = value }
                break
            }
            index += 1
        }
        result.files = Array(argv[index...])
        return result
    }
}
