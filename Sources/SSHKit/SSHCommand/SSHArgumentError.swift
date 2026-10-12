enum SSHArgumentError: Error, Equatable {
    case usage
    case illegalOption(Character)
    case missingArgument(Character)
    case badPort(String)

    var diagnostic: String? {
        switch self {
        case .usage:
            return nil
        case .illegalOption(let option):
            return "ssh: illegal option -- \(option)\n"
        case .missingArgument(let option):
            return "ssh: option requires an argument -- \(option)\n"
        case .badPort(let port):
            return "Bad port '\(port)'\n"
        }
    }
}
