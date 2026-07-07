import Foundation

extension APIClient {
    /// Lists all discussions for a merge request, following GitLab
    /// `X-Next-Page` pagination.
    public func mergeRequestDiscussions(
        projectIDOrEncodedPath project: String,
        mergeRequestIID: Int,
        query: [URLQueryItem] = [],
        maxPages: Int = 100
    ) async throws -> [Discussion] {
        try await paginate(
            "projects/\(project)/merge_requests/\(mergeRequestIID)/discussions",
            query: query,
            maxPages: maxPages)
    }

    /// Lists all discussions for a merge request by repository
    /// reference, following GitLab `X-Next-Page` pagination.
    public func mergeRequestDiscussions(
        project: RepositoryReference,
        mergeRequestIID: Int,
        query: [URLQueryItem] = [],
        maxPages: Int = 100
    ) async throws -> [Discussion] {
        try await mergeRequestDiscussions(
            projectIDOrEncodedPath: project.encodedPath,
            mergeRequestIID: mergeRequestIID,
            query: query,
            maxPages: maxPages)
    }
}
