import Foundation

/// Auto-merge mutations from upstream gh's `pkg/cmd/pr/merge/http.go`.
/// Inputs use pull request node IDs and uppercase GraphQL merge methods
/// (`MERGE`, `SQUASH`, `REBASE`), unlike the REST merge request.
public enum PullRequestMutations {
    public static let enablePullRequestAutoMerge = """
        mutation($input: EnablePullRequestAutoMergeInput!) {
          enablePullRequestAutoMerge(input: $input) { clientMutationId }
        }
        """

    public static let disablePullRequestAutoMerge = """
        mutation($input: DisablePullRequestAutoMergeInput!) {
          disablePullRequestAutoMerge(input: $input) { clientMutationId }
        }
        """
}
