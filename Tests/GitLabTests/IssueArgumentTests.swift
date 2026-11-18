#if !os(Android)  // argv-parsing test; ArgumentParser trips the Android explicit-module scanner
import Foundation
import Testing
@testable import GlabCommand

@Suite struct IssueArgumentTests {
    @Test func parsesPlainNumber() throws {
        let parsed = try IssueArgument.parse("123")
        #expect(parsed.iid == 123)
        #expect(parsed.repoFromURL == nil)
    }

    @Test func parsesHashPrefixedNumber() throws {
        let parsed = try IssueArgument.parse("#42")
        #expect(parsed.iid == 42)
        #expect(parsed.repoFromURL == nil)
    }

    @Test func parsesFlatURL() throws {
        let parsed = try IssueArgument.parse(
            "https://gitlab.com/foo/bar/-/issues/9")
        #expect(parsed.iid == 9)
        let repo = try #require(parsed.repoFromURL)
        #expect(repo.host == "gitlab.com")
        #expect(repo.pathSegments == ["foo", "bar"])
    }

    @Test func parsesNestedSubgroupURL() throws {
        let parsed = try IssueArgument.parse(
            "https://gitlab.com/group/sub/repo/-/issues/7")
        #expect(parsed.iid == 7)
        let repo = try #require(parsed.repoFromURL)
        #expect(repo.pathSegments == ["group", "sub", "repo"])
    }

    @Test func parsesIncidentURL() throws {
        let parsed = try IssueArgument.parse(
            "https://gitlab.com/foo/bar/-/issues/incident/42")
        #expect(parsed.iid == 42)
    }

    @Test(arguments: [
        "-/work_items/6",
        "work_items/6",
        "-/work_items/6/",
        "-/work_items/6/activity",
        "-/work_items/6?foo=bar#note_123",
        "-/work_items/6/merge_requests/99",
        "-/issues/6",
        "issues/6",
        "-/issues/incident/6",
        "issues/incident/6"
    ])
    func parsesIssueURLPaths(_ path: String) throws {
        let parsed = try IssueArgument.parse("https://gitlab.example.com/group/sub/repo/\(path)")
        #expect(parsed.iid == 6)
        let repo = try #require(parsed.repoFromURL)
        #expect(repo.host == "gitlab.example.com")
        #expect(repo.pathSegments == ["group", "sub", "repo"])
    }

    @Test(arguments: [
        "abc",
        "",
        "https://gitlab.example.com/group/sub/repo/-/work_items/incident/6",
        "https://gitlab.example.com/group/sub/repo/work_items/incident/6",
        "https://gitlab.example.com/group/sub/repo/-/work_items/",
        "https://gitlab.example.com/group/sub/repo/-/work_items/nope",
        "https://gitlab.example.com/group/sub/repo/-/work_items/6extra",
        "https://gitlab.example.com/group/sub/repo/-/merge_requests/6",
        "https://gitlab.example.com/repo/-/work_items/6",
        "ftp://gitlab.example.com/group/sub/repo/-/work_items/6"
    ])
    func rejectsInvalidIssueFormat(_ raw: String) {
        #expect(throws: IssueArgumentError.self) {
            do {
                _ = try IssueArgument.parse(raw)
            } catch {
                #expect(error.localizedDescription == "invalid issue format: \"\(raw)\"")
                throw error
            }
        }
    }

    @Test func rejectsNonNumeric() {
        #expect(throws: IssueArgumentError.self) {
            _ = try IssueArgument.parse("abc")
        }
    }

    @Test func rejectsEmpty() {
        #expect(throws: IssueArgumentError.self) {
            _ = try IssueArgument.parse("")
        }
    }
}

#endif  // !os(Android)
