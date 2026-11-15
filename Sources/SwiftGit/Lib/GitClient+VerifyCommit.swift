import Foundation
import GitKit

// Commit signatures, after git's `builtin/verify-commit.c`, `commit.c`
// (`check_commit_signature`) and `log-tree.c` (`show_signature`): the
// signature and the payload it covers come from GitKit's read API, and go
// through the verifier `verify-tag` uses.
extension GitClient {

    /// What `git verify-commit` finds out about one commit.
    public enum CommitVerification: Sendable {
        /// Nothing resolves to `name`.
        case notFound
        /// `name` is an object of `type`, not a commit.
        case notACommit(type: String)
        /// A commit without a signature.
        case unsigned
        /// A signed commit and the check of its signature.
        case checked(SignatureCheck)

        public var succeeded: Bool {
            if case .checked(let check) = self { return check.succeeded }
            return false
        }
    }

    /// Verify the signature of commit `name`, as `git verify-commit` does.
    public func verifyCommit(_ name: String) async throws -> CommitVerification {
        guard let found = try await lookUpObject(name) else { return .notFound }
        guard found.type == "commit" else { return .notACommit(type: found.type) }
        return try await commitSignatureCheck(found.oid).map { .checked($0) } ?? .unsigned
    }

    /// The check of commit `oid`'s signature, as `log --show-signature`
    /// and the `%G` placeholders show it; `nil` when it isn't signed.
    public func commitSignatureCheck(_ oid: String) async throws -> SignatureCheck? {
        // The header of the repository's own hash, as git's
        // `parse_signed_commit` reads it.
        let signatures = try await withRepository { try $0.commitSignatures(oid) }
        guard let signature = signatures.first(where: { $0.field == "gpgsig" }) else { return nil }
        // Each line of the header ends in a newline in git's copy.
        var text = signature.signature
        if !text.hasSuffix("\n") { text += "\n" }
        let payload = Data(signature.signedPayload)
        let signed = SignedObject(object: payload, payload: payload, signature: Data(text.utf8))
        return try await checkSignature(signed, identity: "committer")
    }
}
