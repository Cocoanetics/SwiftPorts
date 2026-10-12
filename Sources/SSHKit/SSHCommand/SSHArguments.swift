struct SSHArguments: Equatable {
    var port: Int?
    var user: String?
    var identityFiles: [String]
    var configOptions: [String]
    var configFile: String
    var configFileWasSpecified: Bool
    var host: String
    var command: [String]
    var configurationDirectives: [String]
}
