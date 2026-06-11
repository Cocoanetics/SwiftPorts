import Foundation
import Testing
@testable import GitHub

@Suite struct RepositoryDecodingTests {
    @Test func decodesOctocatHelloWorld() throws {
        let data = try FixtureLoader.data("repo_octocat_hello_world")
        let repo = try JSONDecoder.gitHub().decode(Repository.self, from: data)

        #expect(repo.name == "Hello-World")
        #expect(repo.fullName == "octocat/Hello-World")
        #expect(repo.owner.login == "octocat")
        #expect(repo.owner.type == .user)
        #expect(repo.private == false)
        #expect(repo.fork == false)
        #expect(repo.defaultBranch == "master")
        #expect(repo.htmlUrl.absoluteString == "https://github.com/octocat/Hello-World")
        #expect(repo.stargazersCount > 0)
        #expect(repo.visibility == .public)
        #expect(repo.parent == nil)
        #expect(repo.source == nil)
    }

    @Test func decodesForkParentAndSource() throws {
        let data = try FixtureLoader.data("repo_fork_libgit2")
        let repo = try JSONDecoder.gitHub().decode(Repository.self, from: data)

        #expect(repo.fullName == "odrobnik/libgit2")
        #expect(repo.fork == true)

        // Fork of a fork: parent is the immediate parent, source the
        // root of the network — the two differ here.
        let parent = try #require(repo.parent)
        #expect(parent.fullName == "ibrahimcetin/libgit2")
        #expect(parent.fork == true)
        #expect(parent.defaultBranch == "main")

        let source = try #require(repo.source)
        #expect(source.fullName == "libgit2/libgit2")
        #expect(source.owner.type == .organization)

        // GitHub doesn't nest deeper than one level.
        #expect(parent.parent == nil)
        #expect(source.source == nil)
    }

    @Test func forkMetadataSurvivesRoundTrip() throws {
        let data = try FixtureLoader.data("repo_fork_libgit2")
        let decoder = JSONDecoder.gitHub()
        let repo = try decoder.decode(Repository.self, from: data)

        let encoded = try JSONEncoder.gitHub().encode(repo)
        let again = try decoder.decode(Repository.self, from: encoded)
        #expect(again.parent?.fullName == "ibrahimcetin/libgit2")
        #expect(again.source?.fullName == "libgit2/libgit2")
    }

    @Test func nilForkMetadataIsOmittedWhenEncoding() throws {
        let data = try FixtureLoader.data("repo_octocat_hello_world")
        let repo = try JSONDecoder.gitHub().decode(Repository.self, from: data)

        let encoded = try JSONEncoder.gitHub().encode(repo)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["parent"] == nil)
        #expect(json["source"] == nil)
    }
}
