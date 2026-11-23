#if !os(Android)  // command tests depend on ArgumentParser
import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShellKit
import Testing
@testable import GitHub
@testable import GhCommand

/// `gh release edit` against a fake GitHub, driven through parsed argv
/// (including ``GhCommand/preprocess(_:)``). Behavior follows
/// cli/cli `pkg/cmd/release/edit` + `shared/fetch.go` at de06af2.
///
/// swift-corelibs-foundation (Linux, Windows) doesn't hand upload
/// bodies to a `URLProtocol`, so wire-payload checks run where the body
/// arrives; ``payloadFromParsedArgv()`` covers the payload everywhere.
extension HTTPMockedNetworkTests {
    @Suite struct ReleaseEditTests {
        // MARK: SDK encoding

        @Test func updateRequestOmitsNilKeys() throws {
            let data = try JSONEncoder.gitHub().encode(ReleaseUpdateRequest())
            #expect(String(decoding: data, as: UTF8.self) == "{}")
        }

        @Test func updateRequestKeepsExplicitFalseAndEmpty() throws {
            let request = ReleaseUpdateRequest(
                tagName: "v1", targetCommitish: "main", name: "", body: "",
                draft: false, prerelease: false, makeLatest: "legacy",
                discussionCategoryName: "Announcements")
            let object = try Self.json(JSONEncoder.gitHub().encode(request))
            #expect(object.count == 8)
            #expect(object["tag_name"] as? String == "v1")
            #expect(object["target_commitish"] as? String == "main")
            #expect(object["name"] as? String == "")
            #expect(object["body"] as? String == "")
            #expect(object["draft"] as? Bool == false)
            #expect(object["prerelease"] as? Bool == false)
            #expect(object["make_latest"] as? String == "legacy")
            #expect(object["discussion_category_name"] as? String == "Announcements")
        }

        // MARK: argv

        @Test func preprocessRewritesBareBoolsOnlyForReleaseEdit() {
            #expect(GhCommand.preprocess(["release", "edit", "v1", "--draft", "--latest=false"])
                    == ["release", "edit", "v1", "--draft=true", "--latest=false"])
            #expect(GhCommand.preprocess(["release", "edit", "v1", "--prerelease", "--verify-tag"])
                    == ["release", "edit", "v1", "--prerelease=true", "--verify-tag=true"])
            // Option values and post-`--` args are never rewritten.
            #expect(GhCommand.preprocess(["release", "edit", "v1", "--notes", "--draft"])
                    == ["release", "edit", "v1", "--notes", "--draft"])
            #expect(GhCommand.preprocess(["release", "edit", "--", "--draft"])
                    == ["release", "edit", "--", "--draft"])
            #expect(GhCommand.preprocess(["release", "create", "v1", "--draft"])
                    == ["release", "create", "v1", "--draft"])
        }

        @Test func preprocessSplitsAttachedLongValues() {
            #expect(GhCommand.preprocess(["release", "edit", "v1", "--notes=", "--title=a=b"])
                    == ["release", "edit", "v1", "--notes", "", "--title", "a=b"])
        }

        @Test func parsesGoBoolSpellingsAndRejectsOthers() throws {
            let command = try Self.parse(["v1", "--draft=F", "--prerelease=1", "--latest=True"])
            #expect(command.draft == ReleaseEditBool(false))
            #expect(command.prerelease == ReleaseEditBool(true))
            #expect(command.latest == ReleaseEditBool(true))
            #expect(throws: (any Error).self) { try Self.parse(["v1", "--draft=yes"]) }
            // pflag bools never consume the next word: `false` is a 2nd tag.
            #expect(throws: (any Error).self) { try Self.parse(["v1", "--draft", "false"]) }
            #expect(throws: (any Error).self) { try Self.parse(["v1", "--latest=legacy"]) }
        }

        /// pflag string options take the next word whatever it looks like,
        /// read `--opt=` as the empty string, and accept a value joined to
        /// the shorthand (`-Fnotes.md`).
        @Test func parsesPflagStringValueForms() throws {
            let dashed = try Self.parse(["v1", "--notes", "- Fixed a bug", "-t", "--draft"])
            #expect(dashed.notes == "- Fixed a bug")
            #expect(dashed.title == "--draft")
            #expect(dashed.draft == nil)

            let emptied = try Self.parse(["--notes=", "v1", "--title="])
            #expect(emptied.tag == "v1")
            #expect(emptied.notes == "")
            #expect(emptied.title == "")

            let joined = try Self.parse(["v1", "-Fnotes.md", "-Rghe.example.com/o/r", "-nNotes", "-tTitle"])
            #expect(joined.notesFile == "notes.md")
            #expect(joined.repo?.host == "ghe.example.com")
            #expect(joined.repo?.reference.slug == "o/r")
            #expect(joined.notes == "Notes")
            #expect(joined.title == "Title")
        }

        @Test func payloadFromParsedArgv() throws {
            let command = try Self.parse([
                "v1", "--title=", "--notes", "- Fixed", "--draft=false", "--latest", "--target", ""
            ])
            let request = command.makeRequest(body: command.notes, currentTagName: "v1")
            let body = try Self.json(JSONEncoder.gitHub().encode(request))
            #expect(body.count == 5)
            #expect(body["tag_name"] as? String == "v1")
            #expect(body["name"] as? String == "")
            #expect(body["body"] as? String == "- Fixed")
            #expect(body["draft"] as? Bool == false)
            #expect(body["make_latest"] as? String == "true")
        }

        @Test func barePositionalWithoutFlagsFailsBeforeAnyRequest() async throws {
            let server = FakeGitHub()
            await #expect(throws: ExitCode(1)) {
                _ = try await Self.run(["v1"], server: server)
            }
            #expect(server.requests.isEmpty)
        }

        // MARK: Published release

        @Test func editsPublishedReleaseByNumericIdWithExplicitEmptiesAndFalse() async throws {
            let server = Self.published(id: 42, tag: "v1.0")
            let out = try await Self.run(
                ["v1.0", "--title", "", "-n", "", "--draft=false", "--latest=false"],
                server: server)

            #expect(out == "https://github.com/cli/cli/releases/tag/v1.0\n")
            #expect(server.rest.map(\.line) == [
                "GET /repos/cli/cli/releases/tags/v1.0",
                "PATCH /repos/cli/cli/releases/42"
            ])
            if let body = try server.payload("PATCH /repos/cli/cli/releases/42") {
                #expect(body.count == 5)
                #expect(body["tag_name"] as? String == "v1.0")
                #expect(body["name"] as? String == "")
                #expect(body["body"] as? String == "")
                #expect(body["draft"] as? Bool == false)
                #expect(body["make_latest"] as? String == "false")
            }
        }

        @Test func dashPrefixedAndAttachedEmptyValuesReachTheWrite() async throws {
            let server = Self.published(id: 42, tag: "v1.0")
            _ = try await Self.run(["v1.0", "--notes", "- Fixed a bug", "--title="], server: server)
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
            if let body = try server.payload("PATCH /repos/cli/cli/releases/42") {
                #expect(body["body"] as? String == "- Fixed a bug")
                #expect(body["name"] as? String == "")
            }
        }

        @Test func titleOnlyEditSendsNoDatesTargetOrStateDefaults() async throws {
            let server = Self.published(id: 42, tag: "v1.0")
            // Empty --tag / --target count as flags but never become keys.
            _ = try await Self.run(["v1.0", "-t", "New", "--tag", "", "--target", ""], server: server)
            if let body = try server.payload("PATCH /repos/cli/cli/releases/42") {
                #expect(body.keys.sorted() == ["name", "tag_name"])
                #expect(body["tag_name"] as? String == "v1.0")
            }
        }

        @Test func repoFlagAloneSatisfiesFlagCheckAndCarriesTag() async throws {
            let server = Self.published(id: 42, tag: "v1.0")
            _ = try await Self.run(["v1.0", "-R", "cli/cli"], server: server)
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
            if let body = try server.payload("PATCH /repos/cli/cli/releases/42") {
                #expect(body.keys.sorted() == ["tag_name"])
            }
        }

        @Test func tagIsOneEscapedPathSegment() async throws {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/release%2F1.0%25%23") {
                (200, Self.release(id: 5, tag: "release/1.0%#"))
            }
            server.route("PATCH", "/repos/cli/cli/releases/5") {
                (200, Self.release(id: 5, tag: "release/1.0%#"))
            }
            _ = try await Self.run(["release/1.0%#", "--prerelease"], server: server)
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
            if let body = try server.payload("PATCH /repos/cli/cli/releases/5") {
                #expect(body["tag_name"] as? String == "release/1.0%#")
                #expect(body["prerelease"] as? Bool == true)
            }
        }

        // MARK: Draft release

        @Test func resolvesDraftThroughGraphQLThenRESTById() async throws {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/v2.0") { (404, #"{"message":"Not Found"}"#) }
            server.route("POST", "/graphql") {
                (200, #"{"data":{"repository":{"release":{"databaseId":7,"isDraft":true}}}}"#)
            }
            server.route("GET", "/repos/cli/cli/releases/7") {
                (200, Self.release(id: 7, tag: "v2.0", draft: true))
            }
            server.route("PATCH", "/repos/cli/cli/releases/7") {
                (200, Self.release(id: 7, tag: "v2.0"))
            }
            _ = try await Self.run(["v2.0", "--draft=false", "--discussion-category", "General"],
                                   server: server)

            // The published lookup races the draft one, so it may land
            // anywhere or be cancelled; only GraphQL → by-id GET → PATCH
            // is ordered.
            let lines = server.requests.map(\.line)
            let graphQL = try #require(lines.firstIndex(of: "POST /graphql"))
            let byID = try #require(lines.firstIndex(of: "GET /repos/cli/cli/releases/7"))
            let patch = try #require(lines.firstIndex(of: "PATCH /repos/cli/cli/releases/7"))
            #expect(graphQL < byID && byID < patch)
            #expect(lines.filter { $0.hasPrefix("PATCH") }.count == 1)

            if let query = try server.payload("POST /graphql") {
                #expect((query["query"] as? String)?.contains("query RepositoryReleaseByTag(") == true)
                let variables = try #require(query["variables"] as? [String: String])
                #expect(variables == ["owner": "cli", "name": "cli", "tagName": "v2.0"])
            }
            if let body = try server.payload("PATCH /repos/cli/cli/releases/7") {
                #expect(body.keys.sorted() == ["discussion_category_name", "draft", "tag_name"])
                #expect(body["draft"] as? Bool == false)
            }
        }

        @Test func failedDraftLookupDoesNotMaskPublishedNotFound() async throws {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/v9") { (404, #"{"message":"Not Found"}"#) }
            server.route("POST", "/graphql") { (200, #"{"data":{"repository":{"release":null}}}"#) }
            await #expect(throws: ReleaseEditError.releaseNotFound) {
                _ = try await Self.run(["v9", "--draft"], server: server)
            }
            #expect(!server.requests.contains { $0.method == "PATCH" })
        }

        @Test func bothLookupsFailingReportsErrorWithoutWrites() async throws {
            // REST 500 + GraphQL 502 reports an error and never falls back
            // to creating or writing anything.
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/v1") { (500, #"{"message":"boom"}"#) }
            server.route("POST", "/graphql") { (502, #"{"message":"bad gateway"}"#) }
            await #expect(throws: APIError.self) {
                _ = try await Self.run(["v1", "--draft"], server: server)
            }
            #expect(server.requests.allSatisfy { $0.method != "PATCH" && $0.path != "/repos/cli/cli/releases" })
        }

        // MARK: Write failures

        @Test func rejectedWriteIsNotRetried() async throws {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/v1") { (200, Self.release(id: 1, tag: "v1")) }
            server.route("PATCH", "/repos/cli/cli/releases/1") { (422, #"{"message":"Validation Failed"}"#) }
            await #expect(throws: APIError.self) {
                _ = try await Self.run(["v1", "-t", "x"], server: server)
            }
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
        }

        @Test func undecodableWriteResponseFailsWithoutSecondWrite() async throws {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/v1") { (200, Self.release(id: 1, tag: "v1")) }
            server.route("PATCH", "/repos/cli/cli/releases/1") { (200, "{}") }
            await #expect(throws: APIError.self) {
                _ = try await Self.run(["v1", "-t", "x"], server: server)
            }
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
        }

        // MARK: Verify tag

        // GraphQL answers both the draft lookup and RepositoryFindRef with
        // one payload, since the operation name is in the (not always
        // delivered) body.

        @Test func verifyTagAbortsWhenReplacementTagIsMissing() async throws {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/v1") { (200, Self.release(id: 1, tag: "v1")) }
            server.route("POST", "/graphql") { (200, #"{"data":{"repository":{"release":null,"ref":null}}}"#) }
            await #expect(throws: ReleaseEditError.tagNotFound(tag: "v2", repo: "cli/cli")) {
                _ = try await Self.run(["v1", "--tag", "v2", "--verify-tag"], server: server)
            }
            #expect(!server.requests.contains { $0.method == "PATCH" })
            if let findRef = try server.payloads("POST /graphql").first(where: {
                ($0["query"] as? String)?.contains("RepositoryFindRef") == true
            }) {
                #expect((findRef["variables"] as? [String: String])?["tagName"] == "refs/tags/v2")
            }
        }

        @Test func verifyTagPassesAndRenames() async throws {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/v1") { (200, Self.release(id: 1, tag: "v1")) }
            server.route("POST", "/graphql") {
                (200, #"{"data":{"repository":{"release":null,"ref":{"id":"REF_1"}}}}"#)
            }
            server.route("PATCH", "/repos/cli/cli/releases/1") { (200, Self.release(id: 1, tag: "v2")) }
            _ = try await Self.run(["v1", "--tag", "v2", "--verify-tag", "--target", "main"], server: server)
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
            if let body = try server.payload("PATCH /repos/cli/cli/releases/1") {
                #expect(body.keys.sorted() == ["tag_name", "target_commitish"])
                #expect(body["tag_name"] as? String == "v2")
            }
        }

        @Test func verifyTagWithoutReplacementTagSkipsTheCheck() async throws {
            let server = Self.published(id: 1, tag: "v1")
            _ = try await Self.run(["v1", "--verify-tag"], server: server)
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
            #expect(try !server.payloads("POST /graphql").contains {
                ($0["query"] as? String)?.contains("RepositoryFindRef") == true
            })
        }

        // MARK: Enterprise host

        @Test func repoFlagKeepsEnterpriseHost() throws {
            let enterprise = try #require(try Self.parse(["v1", "-R", "ghe.example.com/o/r"]).repo)
            #expect(enterprise.host == "ghe.example.com")
            #expect(enterprise.reference.slug == "o/r")
            let dotcom = try #require(try Self.parse(["v1", "-R", "o/r"]).repo)
            #expect(dotcom.host == nil)
            #expect(throws: (any Error).self) { try Self.parse(["v1", "-R", "o"]) }
        }

        @Test func lookupAndWriteUseTheEnterpriseAPIRoot() async throws {
            let server = FakeGitHub()
            server.route("GET", "/api/v3/repos/cli/cli/releases/tags/v1") { (200, Self.release(id: 1, tag: "v1")) }
            server.route("PATCH", "/api/v3/repos/cli/cli/releases/1") { (200, Self.release(id: 1, tag: "v1")) }
            _ = try await Self.run(["v1", "-t", "x"], server: server, host: "ghe.example.com")
            #expect(server.rest.map(\.url) == [
                "https://ghe.example.com/api/v3/repos/cli/cli/releases/tags/v1",
                "https://ghe.example.com/api/v3/repos/cli/cli/releases/1"
            ])
        }

        // MARK: Notes sources

        @Test func notesFileReplacesInlineNotesVerbatim() async throws {
            let root = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let notes = "# Notes\r\n\n- `code` \"quoted\"\n"
            try Data(notes.utf8).write(to: root.appendingPathComponent("notes.md"))
            let server = Self.published(id: 1, tag: "v1")
            _ = try await Self.run(["v1", "--notes", "inline", "-Fnotes.md"], server: server, root: root)
            #expect(server.rest.map(\.method) == ["GET", "PATCH"])
            if let body = try server.payload("PATCH /repos/cli/cli/releases/1") {
                #expect(body["body"] as? String == notes)
            }
        }

        @Test func notesFileDashReadsStdinAndNotesDashIsLiteral() async throws {
            let server = Self.published(id: 1, tag: "v1")
            _ = try await Self.run(["v1", "--notes-file", "-"], server: server, stdin: "from stdin\n")
            if let body = try server.payload("PATCH /repos/cli/cli/releases/1") {
                #expect(body["body"] as? String == "from stdin\n")
            }

            let literal = Self.published(id: 1, tag: "v1")
            _ = try await Self.run(["v1", "--notes", "-"], server: literal, stdin: "unused")
            if let body = try literal.payload("PATCH /repos/cli/cli/releases/1") {
                #expect(body["body"] as? String == "-")
            }
        }

        @Test func notesFileOutsideSandboxIsDeniedBeforeAnyRequest() async throws {
            let root = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let outside = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: outside) }
            let secret = outside.appendingPathComponent("secret.md")
            try Data("secret".utf8).write(to: secret)
            let server = FakeGitHub()
            await #expect(throws: (any Error).self) {
                _ = try await Self.run(["v1", "-F", secret.path], server: server, root: root)
            }
            #expect(server.requests.isEmpty)
        }

        @Test func unreadableNotesFileFailsBeforeAnyRequest() async throws {
            let root = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let server = FakeGitHub()
            await #expect(throws: (any Error).self) {
                _ = try await Self.run(["v1", "-F", "missing.md"], server: server, root: root)
            }
            #expect(server.requests.isEmpty)
        }

        // MARK: Helpers

        private static func parse(_ argv: [String]) throws -> ReleaseEdit {
            let args = GhCommand.preprocess(["release", "edit"] + argv)
            return try ReleaseEdit.parse(Array(args.dropFirst(2)))
        }

        /// A published release `tag` with numeric id `id` that accepts one PATCH.
        private static func published(id: Int, tag: String) -> FakeGitHub {
            let server = FakeGitHub()
            server.route("GET", "/repos/cli/cli/releases/tags/\(tag)") { (200, release(id: id, tag: tag)) }
            server.route("PATCH", "/repos/cli/cli/releases/\(id)") { (200, release(id: id, tag: tag)) }
            return server
        }

        private static func run(
            _ argv: [String],
            server: FakeGitHub,
            stdin: String = "",
            root: URL? = nil,
            host: String = "github.com"
        ) async throws -> String {
            let command = try parse(argv)
            let out = OutputSink()
            var env = Environment()
            if let root { env.workingDirectory = root.path }
            let shell = Shell(
                stdin: .string(stdin), stdout: out, stderr: OutputSink(),
                environment: env,
                sandbox: root.map { Sandbox.rooted(at: $0, allowedHosts: ["api.github.com"]) })
            MockURLProtocol.handler = server.handle
            let session = MockURLProtocol.session()
            let config = Configuration(host: host)
            try await shell.withCurrent {
                try await command.run(
                    target: RepositoryReference(owner: "cli", name: "cli"),
                    api: APIClient(configuration: config, session: session),
                    gql: GraphQLClient(configuration: config, session: session))
            }
            out.finish()
            return await out.readAllString()
        }

        private static func tempDir() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("release-edit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath()
        }

        static func json(_ data: Data) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        static func release(id: Int, tag: String, name: String = "Release", draft: Bool = false) -> String {
            let escapedTag = tag.replacingOccurrences(of: "\"", with: "\\\"")
            return """
                {"id":\(id),"node_id":"RE_\(id)","tag_name":"\(escapedTag)","target_commitish":"main",
                 "name":"\(name)","body":"old","draft":\(draft),"prerelease":false,
                 "created_at":"2026-01-01T00:00:00Z","published_at":"2026-01-02T00:00:00Z",
                 "author":{"id":1,"node_id":"U_1","login":"octocat",
                   "avatar_url":"https://avatars.githubusercontent.com/u/1",
                   "html_url":"https://github.com/octocat","type":"User","site_admin":false},
                 "assets":[],"url":"https://api.github.com/repos/cli/cli/releases/\(id)",
                 "html_url":"https://github.com/cli/cli/releases/tag/v1.0",
                 "assets_url":"https://api.github.com/repos/cli/cli/releases/\(id)/assets",
                 "upload_url":"https://uploads.github.com/repos/cli/cli/releases/\(id)/assets{?name,label}"}
                """
        }
    }

    /// One request the fake saw. `path` is the raw, still-percent-encoded
    /// path, so escaping is asserted exactly.
    struct FakeGitHubRequest {
        let method: String
        let path: String
        let url: String
        let body: Data
        var line: String { "\(method) \(path)" }
    }

    /// Route table + request log for one test.
    final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: () -> (Int, String)] = [:]
        private var log: [FakeGitHubRequest] = []

        var requests: [FakeGitHubRequest] { lock.withLock { log } }

        /// REST traffic only — the draft GraphQL lookup races the
        /// published one, so whether it is logged depends on timing.
        var rest: [FakeGitHubRequest] { requests.filter { !$0.path.hasSuffix("/graphql") } }

        /// JSON body of the first `line` request, which must exist; nil
        /// where the platform doesn't deliver upload bodies.
        func payload(_ line: String) throws -> [String: Any]? {
            let request = try #require(requests.first { $0.line == line })
            return request.body.isEmpty ? nil : try ReleaseEditTests.json(request.body)
        }

        /// JSON bodies of every delivered `line` request.
        func payloads(_ line: String) throws -> [[String: Any]] {
            try requests.filter { $0.line == line && !$0.body.isEmpty }
                .map { try ReleaseEditTests.json($0.body) }
        }

        func route(_ method: String, _ path: String, _ response: @escaping () -> (Int, String)) {
            lock.withLock { routes["\(method) \(path)"] = response }
        }

        func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            let url = try #require(request.url)
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            let method = request.httpMethod ?? "GET"
            let body = try APIClientTests.requestBodyData(from: request)
            let entry = FakeGitHubRequest(method: method, path: path, url: url.absoluteString, body: body)
            let route: (() -> (Int, String))? = lock.withLock {
                log.append(entry)
                return routes[entry.line]
            }
            let (status, json) = route?() ?? (599, #"{"message":"unrouted"}"#)
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!,
                    Data(json.utf8))
        }
    }
}
#endif
