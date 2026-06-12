import ArgumentParser
import ShellKit
import Foundation
import HTTPTypes
import GitHub
import JqKit

struct ApiCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Make an authenticated GitHub API request.",
        discussion: """
        Send a request to the GitHub REST API and print the response.

        Without -X, GET is used; supplying -F or --input switches to POST.

        --jq <filter> runs the response body through an in-process jq
        engine (JqKit) and prints the filter result instead of the raw
        JSON response.

        -F / -f values are sent verbatim as strings (with -F additionally
        coercing 'true', 'false', 'null', and numerics). Object- or
        array-shaped JSON values are NOT parsed; pass complex bodies
        through --input <file|->.

        When the endpoint is `graphql`, fields named `query` and
        `operationName` stay at the top level of the request body and
        every other -f/-F field is folded into `variables`.

        Examples:
          gh api repos/cli/cli
          gh api repos/cli/cli/releases/latest
          gh api -X POST repos/{owner}/{repo}/issues -f title="Hi" -f body="…"
          gh api repos/cli/cli --jq '.full_name'
          gh api graphql -f query='query { viewer { login } }'
          gh api graphql --input request.json
          cat body.json | gh api graphql --input -
        """
    )

    @Argument(help: "API endpoint, e.g. 'repos/cli/cli' or '/users/octocat'.")
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

    @Option(name: .customLong("input"),
            help: "The file to use as body for the HTTP request (use \"-\" to read from standard input).")
    var inputFile: String?

    @Option(name: .customLong("hostname"),
            help: "GitHub host. Defaults to github.com (or $GH_HOST).")
    var hostname: String?

    @Flag(name: [.customShort("i"), .customLong("include")],
          help: "Include HTTP response status line and headers in the output.")
    var includeHeaders: Bool = false

    @Option(name: [.customShort("q"), .customLong("jq")],
            help: "Run a jq filter over the response body before printing.")
    var jqFilter: String?

    func run() async throws {
        let client = try await CommandContext.apiClient(host: hostname)

        let body = try await buildBody()
        // When --input is set the user owns the body; -f/-F instead
        // become endpoint query-string params, per upstream gh.
        let query = inputFile != nil ? try buildQueryItems() : []

        // GraphQL is always POST. -f/-F or --input also implies POST when
        // the user didn't override the method. Matches upstream gh.
        let effectiveMethod: String
        if method == "GET" && (body != nil || Self.isGraphQLEndpoint(endpoint)) {
            effectiveMethod = "POST"
        } else {
            effectiveMethod = method
        }

        let httpMethod = HTTPRequest.Method(effectiveMethod.uppercased())
            ?? HTTPRequest.Method(effectiveMethod)
        guard let httpMethod else {
            throw ValidationError("Unsupported method: \(method)")
        }
        let response = try await client.raw(
            method: httpMethod,
            path: endpoint,
            query: query,
            body: body
        )

        if includeHeaders {
            // The preamble carries its own upstream-exact line
            // endings (`\n` status line, `\r\n` header lines). When
            // the transport doesn't report the negotiated protocol
            // (corelibs never fires URLSessionTaskMetrics), assume
            // HTTP/2 — what GitHub negotiates with both upstream gh
            // and URLSession.
            Shell.print(
                Self.formatIncludeHeaders(
                    proto: response.httpVersion ?? "HTTP/2.0",
                    status: response.status,
                    headerFields: response.headerFields),
                terminator: "")
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

        // Body bytes go out exactly as received — upstream pipes the
        // response through io.Copy when stdout is not a TTY: no
        // re-formatting, no key re-ordering, no added newline (and a
        // 204's empty body prints nothing). Upstream's only other
        // mode is TTY colorized pretty-printing, which the port
        // (colorless throughout) doesn't enter.
        Shell.current.stdout.write(response.body)
    }

    private func buildBody() async throws -> Data? {
        if let inputFile {
            return try await Self.readInputFile(inputFile)
        }
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

        if Self.isGraphQLEndpoint(endpoint) {
            dict = Self.reshapeGraphQLBody(dict)
        }

        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    /// Build URL query items from `-f`/`-F` fields. Used only when
    /// `--input` is set; mirrors upstream's `addQuery(requestPath, params)`
    /// behaviour where field flags become endpoint query-string params.
    /// `-f` values stay as-is; `-F` values are coerced (true/false/null,
    /// integers, doubles) and serialised the same way upstream's
    /// `addQueryParam` formats scalars.
    private func buildQueryItems() throws -> [URLQueryItem] {
        try Self.buildQueryItems(rawFields: rawFields, fields: fields)
    }

    static func buildQueryItems(rawFields: [String], fields: [String]) throws -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        for raw in rawFields {
            let (k, v) = try splitField(raw)
            items.append(URLQueryItem(name: k, value: v))
        }
        for typed in fields {
            let (k, v) = try splitField(typed)
            items.append(URLQueryItem(name: k, value: queryStringValue(coerceField(v))))
        }
        return items
    }

    static func queryStringValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case is NSNull: return ""
        default: return String(describing: value)
        }
    }

    /// Read the body bytes referenced by `--input <file|->`. `-` reads
    /// from standard input; any other value is a path. Mirrors upstream
    /// `gh api`'s `openUserFile` semantics: bytes go on the wire
    /// verbatim, with no parsing.
    static func readInputFile(_ path: String) async throws -> Data {
        if path == "-" {
            return await Shell.current.stdin.readAllData()
        }
        let url = URL(fileURLWithPath: path)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ValidationError("Could not read --input file '\(path)': \(error.localizedDescription)")
        }
    }

    static func isGraphQLEndpoint(_ endpoint: String) -> Bool {
        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed == "graphql"
    }

    /// Reshape a flat field dictionary into the GraphQL request envelope
    /// `{query, variables, operationName}`. Mirrors upstream
    /// `groupGraphQLVariables` exactly: `query` and `operationName`
    /// stay at the top level and every other key is treated as a
    /// variable. Values are not JSON-parsed — for nested-object
    /// variables, callers pass `--input` instead.
    static func reshapeGraphQLBody(_ dict: [String: Any]) -> [String: Any] {
        var topLevel: [String: Any] = [:]
        var variables: [String: Any] = [:]
        for (key, value) in dict {
            switch key {
            case "query", "operationName":
                topLevel[key] = value
            default:
                variables[key] = value
            }
        }
        if topLevel["query"] == nil { topLevel["query"] = "" }
        if !variables.isEmpty { topLevel["variables"] = variables }
        return topLevel
    }

    private func splitField(_ s: String) throws -> (String, String) {
        try Self.splitField(s)
    }

    private func coerce(_ value: String) -> Any {
        Self.coerceField(value)
    }

    static func splitField(_ s: String) throws -> (String, String) {
        guard let eq = s.firstIndex(of: "=") else {
            throw ValidationError("Field '\(s)' must be KEY=VALUE")
        }
        let key = String(s[..<eq])
        let value = String(s[s.index(after: eq)...])
        return (key, value)
    }

    static func coerceField(_ value: String) -> Any {
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
