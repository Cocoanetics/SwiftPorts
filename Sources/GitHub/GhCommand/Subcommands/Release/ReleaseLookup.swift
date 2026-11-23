import Foundation
import GitHub

/// Release lookups shared by `gh release edit`, mirroring upstream's
/// `pkg/cmd/release/shared/fetch.go` and `edit/http.go`.
enum ReleaseLookup {
    /// Find a published release by its tag, or a draft release by its
    /// pending tag (which has no git ref yet, so REST can't see it).
    /// Upstream races both lookups and takes whichever succeeds; one
    /// failed lookup (e.g. the draft query) never masks a release the
    /// other found. When both fail, "release not found" wins.
    static func fetchRelease(
        tag: String,
        target: RepositoryReference,
        api: APIClient,
        gql: GraphQLClient
    ) async throws -> Release {
        let publishedError: Error
        do {
            return try await fetchReleasePath(
                ["repos", target.owner, target.name, "releases", "tags", tag], api: api)
        } catch {
            publishedError = error
        }
        do {
            return try await fetchDraftRelease(tag: tag, target: target, api: api, gql: gql)
        } catch let draftError as ReleaseEditError where draftError == .releaseNotFound {
            throw draftError
        } catch {
            throw publishedError
        }
    }

    /// `RepositoryFindRef`: does `refs/tags/<tag>` exist on the remote?
    static func remoteTagExists(
        tag: String,
        target: RepositoryReference,
        gql: GraphQLClient
    ) async throws -> Bool {
        let payload: FindRefPayload = try await gql.query(
            """
            query RepositoryFindRef($owner: String!, $name: String!, $tagName: String!) {
              repository(owner: $owner, name: $name) { ref(qualifiedName: $tagName) { id } }
            }
            """,
            variables: [
                "owner": .string(target.owner),
                "name": .string(target.name),
                "tagName": .string("refs/tags/\(tag)"),
            ],
            operationName: "RepositoryFindRef")
        return !(payload.repository.ref?.id ?? "").isEmpty
    }

    /// Absolute API URL with each segment escaped on its own, like
    /// upstream's `safeurl.JoinPath` — a tag such as `release/1.0`
    /// stays one segment (`release%2F1.0`). An absolute URL bypasses
    /// `APIClient`'s own path appending, which would re-escape `%`.
    static func url(_ segments: [String], api: APIClient) async -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let path = segments
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        var root = await api.configuration.apiRoot.absoluteString
        if !root.hasSuffix("/") { root += "/" }
        return root + path
    }

    private static func fetchDraftRelease(
        tag: String,
        target: RepositoryReference,
        api: APIClient,
        gql: GraphQLClient
    ) async throws -> Release {
        let payload: ReleaseByTagPayload = try await gql.query(
            """
            query RepositoryReleaseByTag($owner: String!, $name: String!, $tagName: String!) {
              repository(owner: $owner, name: $name) { release(tagName: $tagName) { databaseId isDraft } }
            }
            """,
            variables: [
                "owner": .string(target.owner),
                "name": .string(target.name),
                "tagName": .string(tag),
            ],
            operationName: "RepositoryReleaseByTag")
        guard let release = payload.repository.release, release.isDraft else {
            throw ReleaseEditError.releaseNotFound
        }
        return try await fetchReleasePath(
            ["repos", target.owner, target.name, "releases", String(release.databaseId)],
            api: api)
    }

    private static func fetchReleasePath(_ segments: [String], api: APIClient) async throws -> Release {
        do {
            return try await api.get(await url(segments, api: api))
        } catch APIError.notFound {
            throw ReleaseEditError.releaseNotFound
        }
    }

    private struct ReleaseByTagPayload: Decodable, Sendable {
        struct Repository: Decodable, Sendable {
            struct DraftRelease: Decodable, Sendable {
                let databaseId: Int
                let isDraft: Bool
            }
            let release: DraftRelease?
        }
        let repository: Repository
    }

    private struct FindRefPayload: Decodable, Sendable {
        struct Repository: Decodable, Sendable {
            struct Ref: Decodable, Sendable { let id: String }
            let ref: Ref?
        }
        let repository: Repository
    }
}
