import Foundation
import CGitKit

// The signature check `git merge --verify-signatures` (and `git pull`)
// makes of each commit it merges, after git's `commit.c`
// (`verify_merge_signature`).
extension GitClient {

    /// What git's `verify_merge_signature` decides about one commit, with
    /// the commit's unique abbreviation and the signer (`nil` when the
    /// check names none, which git prints as `(null)`).
    public enum MergeSignatureVerdict: Sendable, Equatable {
        case good(abbreviation: String, signer: String?)
        case untrusted(abbreviation: String, signer: String?)
        case bad(abbreviation: String, signer: String?)
        case unsigned(abbreviation: String)
    }

    /// Check commit `oid` as git checks a commit before merging it: a
    /// good signature is untrusted when the check failed, or, with
    /// `checkTrust`, when the key is trusted less than `marginal`; a bad
    /// one is bad; anything else (none, an expired or revoked key, a
    /// missing key) has no signature.
    public func mergeSignatureVerdict(_ oid: String, checkTrust: Bool) async throws -> MergeSignatureVerdict {
        let check = try await commitSignatureCheck(oid) ?? .unsigned
        let abbreviation = try await uniqueAbbreviation(oid)
        switch check.result {
        case "G":
            if !check.succeeded || (checkTrust && check.trust < 2) {
                return .untrusted(abbreviation: abbreviation, signer: check.signer)
            }
            return .good(abbreviation: abbreviation, signer: check.signer)
        case "B":
            return .bad(abbreviation: abbreviation, signer: check.signer)
        default:
            return .unsigned(abbreviation: abbreviation)
        }
    }

    /// git's `repo_find_unique_abbrev_r(…, DEFAULT_ABBREV)`: the shortest
    /// unique prefix of `oid`, at least `core.abbrev` long.
    func uniqueAbbreviation(_ oid: String) async throws -> String {
        try await withRepository { _ in
            var repo: OpaquePointer?
            var object: OpaquePointer?
            var buffer = git_buf()
            defer {
                git_buf_dispose(&buffer)
                git_object_free(object)
                git_repository_free(repo)
            }
            try Self.check(git_repository_open_ext(&repo, workingDirectory.path, 0, nil))
            var id = git_oid()
            guard git_oid_fromstr(&id, oid) == 0,
                  git_object_lookup(&object, repo, &id, GIT_OBJECT_ANY) == 0,
                  git_object_short_id(&buffer, object) == 0, let pointer = buffer.ptr
            else { return String(oid.prefix(7)) }
            return String(cString: pointer)
        }
    }
}
