import ArgumentParser
import ShellKit
import Foundation
import HTTPTypes
import GitLab
import JqKit

struct ApiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Make an authenticated GitLab REST API request.",
        discussion: """
        Send a request to the GitLab REST API and print the response.

        Without -X, GET is used. Field flags switch to POST automatically.

        --jq <filter> runs the response body through an in-process jq
        engine (JqKit) and prints the filter result instead of the raw
        JSON response.

        Examples:
          glab api projects/group%2Frepo
          glab api -X POST projects/123/issues -f title="Hi" -f body="…"
          glab api projects/26 --jq '.name'
        """
    )

    @Argument(help: "API endpoint, e.g. 'projects/123' or '/user'.")
    var endpoint: String

    @Option(name: [.customShort("X"), .customLong("method")],
            help: "HTTP method (GET, POST, PATCH, PUT, DELETE, HEAD).")
    var method: String = "GET"

    @Option(name: [.customShort("F"), .customLong("field")],
            parsing: .singleValue,
            help: "Add a typed field to the request body. KEY=VALUE; values 'true'/'false'/numerics are encoded as such.")
    var fields: [String] = []

    @Option(name: [.customShort("f"), .customLong("raw-field")],
            parsing: .singleValue,
            help: "Add a string field to the request body. KEY=VALUE.")
    var rawFields: [String] = []

    @Option(name: .customLong("hostname"),
            help: "GitLab host. Defaults to gitlab.com (or $GITLAB_HOST).")
    var hostname: String?

    @Flag(name: [.customShort("i"), .customLong("include")],
          help: "Include HTTP response status line and headers.")
    var includeHeaders: Bool = false

    @Option(name: [.customShort("q"), .customLong("jq")],
            help: "Run a jq filter over the response body before printing.")
    var jqFilter: String?

    func run() async throws {
        let client = try await CommandContext.apiClient(host: hostname)

        let httpMethod = HTTPRequest.Method(method.uppercased())
            ?? HTTPRequest.Method(method)
        guard let httpMethod else {
            throw ValidationError("Unsupported method: \(method)")
        }

        let body = try buildBody()
        let response = try await client.raw(
            method: httpMethod,
            path: endpoint,
            body: body)

        if includeHeaders {
            Shell.print("HTTP \(response.status)")
            if let ct = response.contentType { Shell.print("Content-Type: \(ct)") }
            Shell.print("")
        }

        let isJSON = response.contentType?.contains("json") ?? false

        if let filter = jqFilter, isJSON {
            do {
                let lines = try Jq.evalString(filter: filter, on: response.body)
                for line in lines { Shell.print(line) }
            } catch let e as JqError {
                throw ValidationError("jq: \(e.message)")
            }
            return
        }

        // Body bytes go out exactly as received — upstream glab pipes
        // the response through io.Copy when color is off (its
        // processResponse), same as gh: no re-formatting, no added
        // newline, 204 prints nothing.
        Shell.current.stdout.write(response.body)
    }

    private func buildBody() throws -> Data? {
        guard !fields.isEmpty || !rawFields.isEmpty else { return nil }
        var dict: [String: Any] = [:]
        for raw in rawFields {
            let (k, v) = try splitField(raw)
            dict[k] = v
        }
        for typed in fields {
            let (k, v) = try splitField(typed)
            dict[k] = coerce(v)
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    private func splitField(_ s: String) throws -> (String, String) {
        guard let eq = s.firstIndex(of: "=") else {
            throw ValidationError("Field '\(s)' must be KEY=VALUE")
        }
        let key = String(s[..<eq])
        let value = String(s[s.index(after: eq)...])
        return (key, value)
    }

    private func coerce(_ value: String) -> Any {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        case "null": return NSNull()
        default: break
        }
        if let i = Int(value) { return i }
        if let d = Double(value) { return d }
        return value
    }
}
