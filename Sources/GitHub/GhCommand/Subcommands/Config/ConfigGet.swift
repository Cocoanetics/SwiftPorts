import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ConfigGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print the value for a config key."
    )

    @Argument(help: "Config key (e.g. git_protocol, editor).")
    var key: String

    func run() async throws {
        let store = ConfigFileStore()
        let file = try store.read()
        if let value = file[key] {
            Stdio.print(value)
        } else {
            Stdio.stderr.write(Data("\(key) not set\n".utf8))
            throw ExitCode(1)
        }
    }
}
