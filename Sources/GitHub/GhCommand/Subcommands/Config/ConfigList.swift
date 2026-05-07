import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ConfigList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Print every set config key and its value."
    )

    func run() async throws {
        let store = ConfigFileStore()
        let file = try store.read()
        if file.values.isEmpty {
            Stdio.print("(no config set; \(store.path.path))")
            return
        }
        for key in file.values.keys.sorted() {
            if let value = file[key] {
                Stdio.print("\(key)=\(value)")
            }
        }
    }
}
