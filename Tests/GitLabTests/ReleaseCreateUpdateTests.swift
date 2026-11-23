#if !os(Android)  // command tests depend on ArgumentParser
import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShellKit
import Testing
@testable import GitLab
@testable import GlabCommand

/// `glab release create`'s create-or-update flow against a fake GitLab,
/// driven through parsed argv. Behavior follows gitlab-org/cli
/// `internal/commands/release/create/create.go` at 74ee3ce.
///
/// Wire payloads are asserted on every platform: `MockURLProtocol`
/// restores corelibs' upload bodies (see `URLRequest+UploadBody`).
extension HTTPMockedNetworkTests {
    @Suite struct ReleaseCreateUpdateTests {
        static let project = "/api/v4/projects/group%2Fsub%2Frepo"

        // MARK: SDK encoding

        @Test func updateRequestOmitsNilKeys() throws {
            let data = try JSONEncoder.gitLab().encode(ReleaseUpdateRequest())
            #expect(String(decoding: data, as: UTF8.self) == "{}")
        }

        @Test func updateRequestKeepsEmptyValuesAndEncodesDate() throws {
            let date = try #require(ISO8601DateFormatter().date(from: "2026-01-15T10:00:00Z"))
            let request = ReleaseUpdateRequest(
                name: "", description: "", milestones: [], releasedAt: date)
            let object = try Self.json(JSONEncoder.gitLab().encode(request))
            #expect(object.count == 4)
            #expect(object["name"] as? String == "")
            #expect(object["description"] as? String == "")
            #expect(object["milestones"] as? [String] == [])
            #expect(object["released_at"] as? String == "2026-01-15T10:00:00Z")
        }

        // MARK: argv

        @Test func thereIsNoReleaseUpdateCommand() {
            #expect(throws: (any Error).self) {
                _ = try GlabCommand.parseAsRoot(["release", "update", "v1"])
            }
        }

        @Test func noUpdateTakesPflagBoolForms() throws {
            #expect(GlabCommand.preprocess(["release", "create", "v1", "--no-update"])
                    == ["release", "create", "v1", "--no-update=true"])
            #expect(GlabCommand.preprocess(["release", "create", "v1", "-N", "--no-update"])
                    == ["release", "create", "v1", "-N", "--no-update"])
            #expect(GlabCommand.preprocess(["release", "list", "--no-update"])
                    == ["release", "list", "--no-update"])
            #expect(try Self.parse(["v1", "--no-update"]).noUpdate)
            #expect(try Self.parse(["v1", "--no-update=T"]).noUpdate)
            #expect(try !Self.parse(["v1", "--no-update=false"]).noUpdate)
            #expect(try !Self.parse(["v1"]).noUpdate)
            #expect(throws: (any Error).self) { try Self.parse(["v1", "--no-update=maybe"]) }
        }

        // MARK: Payloads

        @Test func updatePayloadResendsCurrentValuesUnlessOverridden() throws {
            let existing = try JSONDecoder.gitLab().decode(
                Release.self, from: Data(Self.release(name: "Old", description: "keep me").utf8))
            let renamed = try Self.parse(["v1.0", "-n", "New", "-r", "main"])
                .updateRequest(existing: existing, notes: "", noteProvided: false)
            #expect(try Self.json(JSONEncoder.gitLab().encode(renamed))
                    as NSDictionary == ["name": "New", "description": "keep me"])

            let cleared = try Self.parse(["v1.0", "-N", ""])
                .updateRequest(existing: existing, notes: "", noteProvided: true)
            #expect(try Self.json(JSONEncoder.gitLab().encode(cleared))
                    as NSDictionary == ["name": "Old", "description": ""])

            let unnamed = try JSONDecoder.gitLab().decode(
                Release.self, from: Data(Self.release(name: nil, description: nil).utf8))
            let fallback = try Self.parse(["v1.0", "-n", ""])
                .updateRequest(existing: unnamed, notes: "", noteProvided: false)
            #expect(try Self.json(JSONEncoder.gitLab().encode(fallback))
                    as NSDictionary == ["name": "v1.0", "description": ""])
        }

        @Test func createPayloadOmitsEmptyNotesAndRef() throws {
            let bare = try Self.parse(["v1.0"]).createBody(notes: "", ref: "")
            #expect(try Self.json(JSONEncoder.gitLab().encode(bare))
                    as NSDictionary == ["tag_name": "v1.0", "name": "v1.0"])
            let full = try Self.parse(["v1.0", "-n", "Name"]).createBody(notes: "notes", ref: "trunk")
            #expect(try Self.json(JSONEncoder.gitLab().encode(full)) as NSDictionary
                    == ["tag_name": "v1.0", "name": "Name", "description": "notes", "ref": "trunk"])
        }

        // MARK: Existing release → one PUT

        @Test func updatesNameAndKeepsExistingDescription() async throws {
            let server = Self.server(existing: Self.release(name: "Old", description: "keep me"))
            server.route("PUT", "\(Self.project)/releases/v1.0") { (200, Self.release(name: "New")) }
            let out = try await Self.run(["v1.0", "-n", "New", "-r", "main"], server: server)

            #expect(server.requests.map(\.line) == [
                "GET \(Self.project)/releases/v1.0",
                "PUT \(Self.project)/releases/v1.0"
            ])
            // Upstream resends name + description; ref never goes into an update,
            // and no date / milestones are injected.
            let body = try server.payload(1)
            #expect(body.count == 2)
            #expect(body["name"] as? String == "New")
            #expect(body["description"] as? String == "keep me")
            #expect(out.contains("• Creating or updating release repo=group/sub/repo tag=v1.0\n"))
            #expect(out.contains("✓ Release updated\turl=https://gitlab.com/group/sub/repo/-/releases/v1.0\n"))
            #expect(out.contains("✓ Release succeeded after "))
        }

        @Test func explicitEmptyNotesClearDescriptionAndKeepName() async throws {
            let server = Self.server(existing: Self.release(name: "Old", description: "gone"))
            server.route("PUT", "\(Self.project)/releases/v1.0") { (200, Self.release()) }
            _ = try await Self.run(["v1.0", "-N", "", "-r", "main"], server: server)
            #expect(server.requests.map(\.method) == ["GET", "PUT"])
            let body = try server.payload(1)
            #expect(body["name"] as? String == "Old")
            #expect(body["description"] as? String == "")
        }

        @Test func missingNameFallsBackToTag() async throws {
            let server = Self.server(existing: Self.release(name: nil, description: nil))
            server.route("PUT", "\(Self.project)/releases/v1.0") { (200, Self.release()) }
            _ = try await Self.run(["v1.0", "-n", "", "-r", "main"], server: server)
            #expect(server.requests.map(\.method) == ["GET", "PUT"])
            let body = try server.payload(1)
            #expect(body["name"] as? String == "v1.0")
            #expect(body["description"] as? String == "")
        }

        @Test func noUpdateRefusesExistingRelease() async throws {
            let server = Self.server(existing: Self.release())
            await #expect(throws: ReleaseCreateError.self) {
                _ = try await Self.run(["v1.0", "-N", "x", "-r", "main", "--no-update"], server: server)
            }
            #expect(server.requests.map(\.method) == ["GET"])
        }

        @Test func explicitFalseNoUpdateStillUpdates() async throws {
            let server = Self.server(existing: Self.release())
            server.route("PUT", "\(Self.project)/releases/v1.0") { (200, Self.release()) }
            _ = try await Self.run(["v1.0", "-N", "x", "-r", "main", "--no-update=false"], server: server)
            #expect(server.requests.map(\.method) == ["GET", "PUT"])

            let guarded = Self.server(existing: Self.release())
            await #expect(throws: ReleaseCreateError.self) {
                _ = try await Self.run(["v1.0", "-N", "x", "-r", "main", "--no-update=true"], server: guarded)
            }
            #expect(guarded.requests.map(\.method) == ["GET"])
        }

        @Test func rejectedUpdateIsNotRetriedOrRecreated() async throws {
            let server = Self.server(existing: Self.release())
            server.route("PUT", "\(Self.project)/releases/v1.0") { (422, #"{"message":"invalid"}"#) }
            await #expect(throws: APIError.self) {
                _ = try await Self.run(["v1.0", "-N", "x", "-r", "main"], server: server)
            }
            #expect(server.requests.map(\.method) == ["GET", "PUT"])
        }

        // MARK: Absent release → POST

        @Test(arguments: [404, 403])
        func absentOrForbiddenLookupCreates(status: Int) async throws {
            let server = FakeGitLab()
            server.route("GET", "\(Self.project)/releases/v1.0") { (status, #"{"message":"x"}"#) }
            server.route("POST", "\(Self.project)/releases") { (201, Self.release()) }
            let out = try await Self.run(["v1.0", "-r", "abc123"], server: server)
            #expect(server.requests.map(\.method) == ["GET", "POST"])
            // Empty notes are omitted; the name falls back to the tag.
            let body = try server.payload(1)
            #expect(body.count == 3)
            #expect(body["tag_name"] as? String == "v1.0")
            #expect(body["name"] as? String == "v1.0")
            #expect(body["ref"] as? String == "abc123")
            #expect(out.contains("✓ Release created:\turl="))
        }

        @Test func otherLookupFailuresStopWithoutWriting() async throws {
            let server = FakeGitLab()
            server.route("GET", "\(Self.project)/releases/v1.0") { (500, #"{"message":"boom"}"#) }
            await #expect(throws: APIError.self) {
                _ = try await Self.run(["v1.0", "-r", "main"], server: server)
            }
            #expect(server.requests.map(\.method) == ["GET"])
        }

        @Test func missingTagWithoutRefUsesDefaultBranch() async throws {
            let server = FakeGitLab()
            server.route("GET", "\(Self.project)/repository/tags/v1.0") { (404, #"{"message":"404 Tag Not Found"}"#) }
            server.route("GET", Self.project) {
                (200, #"""
                    {"id":1,"name":"repo","path":"repo","path_with_namespace":"group/sub/repo",
                     "default_branch":"trunk","visibility":"private","web_url":"https://gitlab.com/group/sub/repo"}
                    """#)
            }
            server.route("GET", "\(Self.project)/releases/v1.0") { (404, #"{"message":"x"}"#) }
            server.route("POST", "\(Self.project)/releases") { (201, Self.release()) }
            let out = try await Self.run(["v1.0", "-N", "notes"], server: server)
            #expect(server.requests.map(\.line) == [
                "GET \(Self.project)/repository/tags/v1.0",
                "GET \(Self.project)",
                "GET \(Self.project)/releases/v1.0",
                "POST \(Self.project)/releases"
            ])
            let body = try server.payload(3)
            #expect(body["ref"] as? String == "trunk")
            #expect(body["description"] as? String == "notes")
            #expect(out.hasPrefix("• Validating tag v1.0\n• Tag does not exist.\n"))
            #expect(out.contains("• using default branch \"trunk\" as ref\n"))
        }

        @Test func existingTagWithoutRefSendsNoRefOnCreate() async throws {
            let server = FakeGitLab()
            server.route("GET", "\(Self.project)/repository/tags/v1.0") { (200, #"{"name":"v1.0"}"#) }
            server.route("GET", "\(Self.project)/releases/v1.0") { (404, #"{"message":"x"}"#) }
            server.route("POST", "\(Self.project)/releases") { (201, Self.release()) }
            _ = try await Self.run(["v1.0"], server: server)
            #expect(server.requests.map(\.method) == ["GET", "GET", "POST"])
            let body = try server.payload(2)
            #expect(body["ref"] == nil)
        }

        @Test func tagIsOneEscapedPathSegment() async throws {
            let server = FakeGitLab()
            let tag = "release%2F1.0%25%3F%23"
            server.route("GET", "\(Self.project)/releases/\(tag)") { (200, Self.release()) }
            server.route("PUT", "\(Self.project)/releases/\(tag)") { (200, Self.release()) }
            _ = try await Self.run(["release/1.0%?#", "-r", "main", "-N", "x"], server: server)
            #expect(server.requests.map(\.method) == ["GET", "PUT"])
        }

        // MARK: Notes sources

        @Test func inlineNotesWinAndIgnoredFileIsNeverRead() async throws {
            let server = Self.server(existing: Self.release())
            server.route("PUT", "\(Self.project)/releases/v1.0") { (200, Self.release()) }
            let stdin = InputSource.string("untouched")
            let (_, err) = try await Self.runCapturing(
                ["v1.0", "-N", "inline", "-F", "-", "-r", "main"], server: server, stdin: stdin)
            #expect(server.requests.map(\.method) == ["GET", "PUT"])
            let body = try server.payload(1)
            #expect(body["description"] as? String == "inline")
            #expect(err.contains("--notes and --notes-file were both given: using --notes and ignoring --notes-file."))
            #expect(String(decoding: await stdin.readAllData(), as: UTF8.self) == "untouched")
        }

        @Test func notesFileAndStdinAreVerbatim() async throws {
            let root = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let notes = "## Changes\r\n\n- `x` \"y\"\n"
            try Data(notes.utf8).write(to: root.appendingPathComponent("CHANGELOG.md"))
            let server = Self.server(existing: Self.release())
            server.route("PUT", "\(Self.project)/releases/v1.0") { (200, Self.release()) }
            _ = try await Self.run(["v1.0", "-F", "CHANGELOG.md", "-r", "main"], server: server, root: root)
            #expect(server.requests.map(\.method) == ["GET", "PUT"])
            let body = try server.payload(1)
            #expect(body["description"] as? String == notes)

            let piped = Self.server(existing: Self.release())
            piped.route("PUT", "\(Self.project)/releases/v1.0") { (200, Self.release()) }
            _ = try await Self.run(["v1.0", "-F", "-", "-r", "main"], server: piped,
                                   stdin: .string("from stdin\n"))
            let pipedBody = try piped.payload(1)
            #expect(pipedBody["description"] as? String == "from stdin\n")
        }

        @Test func notesFileOutsideSandboxIsDeniedBeforeAnyRequest() async throws {
            let root = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let outside = try Self.tempDir()
            defer { try? FileManager.default.removeItem(at: outside) }
            let secret = outside.appendingPathComponent("secret.md")
            try Data("secret".utf8).write(to: secret)
            let server = FakeGitLab()
            await #expect(throws: (any Error).self) {
                _ = try await Self.run(["v1.0", "-F", secret.path, "-r", "main"], server: server, root: root)
            }
            #expect(server.requests.isEmpty)
        }

        // MARK: Helpers

        private static func server(existing: String) -> FakeGitLab {
            let server = FakeGitLab()
            server.route("GET", "\(project)/releases/v1.0") { (200, existing) }
            return server
        }

        private static func run(
            _ argv: [String], server: FakeGitLab,
            stdin: InputSource = .empty, root: URL? = nil
        ) async throws -> String {
            try await runCapturing(argv, server: server, stdin: stdin, root: root).stdout
        }

        private static func runCapturing(
            _ argv: [String], server: FakeGitLab,
            stdin: InputSource = .empty, root: URL? = nil
        ) async throws -> (stdout: String, stderr: String) {
            let command = try parse(argv)
            let out = OutputSink()
            let err = OutputSink()
            var env = Environment()
            if let root { env.workingDirectory = root.path }
            let shell = Shell(
                stdin: stdin, stdout: out, stderr: err, environment: env,
                sandbox: root.map { Sandbox.rooted(at: $0, allowedHosts: ["gitlab.com"]) })
            MockURLProtocol.handler = server.handle
            let client = APIClient(configuration: Configuration(), session: MockURLProtocol.session())
            try await shell.withCurrent {
                try await command.run(
                    target: RepositoryReference(pathSegments: ["group", "sub", "repo"]),
                    client: client)
            }
            out.finish()
            err.finish()
            return (await out.readAllString(), await err.readAllString())
        }

        private static func parse(_ argv: [String]) throws -> ReleaseCreate {
            let args = GlabCommand.preprocess(["release", "create"] + argv)
            return try ReleaseCreate.parse(Array(args.dropFirst(2)))
        }

        private static func tempDir() throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("release-create-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.resolvingSymlinksInPath()
        }

        static func json(_ data: Data) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        static func release(name: String? = "Release", description: String? = "old") -> String {
            func field(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
            return """
                {"tag_name":"v1.0","name":\(field(name)),"description":\(field(description)),
                 "created_at":"2026-01-01T00:00:00Z","released_at":"2026-01-02T00:00:00Z",
                 "_links":{"self":"https://gitlab.com/group/sub/repo/-/releases/v1.0"}}
                """
        }
    }

    /// Route table + request log; paths stay percent-encoded.
    struct FakeGitLabRequest {
        let method: String
        let path: String
        let body: Data
        var line: String { "\(method) \(path)" }
    }

    final class FakeGitLab: @unchecked Sendable {
        private let lock = NSLock()
        private var routes: [String: () -> (Int, String)] = [:]
        private var log: [FakeGitLabRequest] = []

        var requests: [FakeGitLabRequest] { lock.withLock { log } }

        /// JSON body of request `index`; both must exist.
        func payload(_ index: Int) throws -> [String: Any] {
            let all = requests
            try #require(index < all.count)
            return try ReleaseCreateUpdateTests.json(all[index].body)
        }

        func route(_ method: String, _ path: String, _ response: @escaping () -> (Int, String)) {
            lock.withLock { routes["\(method) \(path)"] = response }
        }

        func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
            let url = try #require(request.url)
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            let method = request.httpMethod ?? "GET"
            let route: (() -> (Int, String))? = lock.withLock {
                log.append(FakeGitLabRequest(method: method, path: path, body: requestBodyData(request)))
                return routes["\(method) \(path)"]
            }
            let (status, json) = route?() ?? (599, #"{"message":"unrouted"}"#)
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!,
                    Data(json.utf8))
        }
    }
}
#endif
