import Foundation

/// Thrown when the remote `git-upload-pack` / `git-receive-pack` /
/// `git-upload-archive` process exits non-zero before libgit2 got whatever
/// reply it was expecting — e.g. the repository path doesn't exist on the
/// remote. Carries the remote's own stderr text when it wrote any,
/// matching what `ssh user@host 'git-upload-pack ...'` would print on a
/// terminal, instead of the generic EOF/protocol failure libgit2's smart
/// transport would otherwise raise.
struct GitKitSSHRemoteCommandError: Error, LocalizedError {
    let exitStatus: Int32
    let stderrText: String

    var errorDescription: String? {
        stderrText.isEmpty
            ? "remote command exited with status \(exitStatus)"
            : stderrText
    }
}
