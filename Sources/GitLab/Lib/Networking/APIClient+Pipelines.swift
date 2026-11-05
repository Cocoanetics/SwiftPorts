import Foundation

extension APIClient {
    /// Creates a pipeline for `ref` (`POST /projects/:id/pipeline`), as
    /// `glab ci run` does.
    public func createPipeline(
        projectIDOrEncodedPath project: String,
        ref: String,
        variables: [PipelineCreateRequest.Variable] = []
    ) async throws -> Pipeline {
        try await send(
            method: .post,
            path: "projects/\(project)/pipeline",
            body: PipelineCreateRequest(ref: ref, variables: variables))
    }

    /// Creates a pipeline for `ref` by repository reference.
    public func createPipeline(
        project: RepositoryReference,
        ref: String,
        variables: [PipelineCreateRequest.Variable] = []
    ) async throws -> Pipeline {
        try await createPipeline(
            projectIDOrEncodedPath: project.encodedPath,
            ref: ref,
            variables: variables)
    }
}
