import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct VariableSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Create or update a CI/CD variable."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Flag(name: [.customShort("p"), .customLong("protected")],
          help: "Mark the variable protected.")
    var `protected`: Bool = false

    @Flag(name: [.customShort("m"), .customLong("masked")],
          help: "Mark the variable masked in job logs.")
    var masked: Bool = false

    @Flag(name: .customLong("raw"),
          help: "Treat the value as raw — disable variable expansion.")
    var raw: Bool = false

    @Option(name: [.customShort("t"), .customLong("type")],
            help: "Variable type: `env_var` (default) or `file`.")
    var variableType: String?

    @Option(name: .customLong("scope"),
            help: "Environment scope. Defaults to all (`*`).")
    var scope: String?

    @Argument(help: "Variable name.")
    var key: String

    @Argument(help: "Value. Use `-` to read from stdin.")
    var value: String

    private struct CreateBody: Encodable {
        let key: String
        let value: String
        let variableType: String?
        let `protected`: Bool
        let masked: Bool
        let raw: Bool
        let environmentScope: String?
    }
    private struct UpdateBody: Encodable {
        let value: String
        let variableType: String?
        let `protected`: Bool
        let masked: Bool
        let raw: Bool
        let environmentScope: String?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        let resolved: String
        if value == "-" {
            resolved = String(decoding: Stdio.stdin.availableData,
                              as: UTF8.self)
        } else {
            resolved = value
        }

        // GitLab returns 404 if the variable doesn't exist, 200 if it
        // does. Try update first; fall back to create on 404.
        let path = "projects/\(target.encodedPath)/variables/\(key)"
        let updateBody = UpdateBody(
            value: resolved, variableType: variableType,
            protected: `protected`, masked: masked, raw: raw,
            environmentScope: scope)
        do {
            let _: Variable = try await client.send(
                method: .put, path: path, body: updateBody)
            Stdio.print("Updated \(key)")
            return
        } catch {
            // Fall through to create.
        }

        let createBody = CreateBody(
            key: key, value: resolved, variableType: variableType,
            protected: `protected`, masked: masked, raw: raw,
            environmentScope: scope)
        let _: Variable = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/variables",
            body: createBody)
        Stdio.print("Created \(key)")
    }
}
