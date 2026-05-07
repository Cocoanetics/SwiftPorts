import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ConfigSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set a config value.",
        discussion: "Writes ~/.config/gh/config.yml. Empty value removes the key."
    )

    @Argument(help: "Config key.")
    var key: String

    @Argument(help: "New value. Omit to remove the key.")
    var value: String?

    func run() async throws {
        let store = ConfigFileStore()
        var file = try store.read()
        if let value, !value.isEmpty {
            file[key] = value
            Stdio.print("✓ Set \(key) = \(value)")
        } else {
            file[key] = nil
            Stdio.print("✓ Unset \(key)")
        }
        try store.write(file)
    }
}
