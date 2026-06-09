import Foundation
import ForgeKit
import libgit2

/// What `git checkout -b` did. Real git distinguishes "switched to a
/// new branch 'X'" (created fresh) from "switched to and reset
/// branch 'X'" (the `-B` force-reset case).
public enum CheckoutBranchOutcome: Sendable {
    case createdNew(name: String)
    case resetExisting(name: String)
}

extension GitClient {

    /// Create a new branch (or reset an existing one with `force=true`)
    /// at `startPoint` (default: HEAD), then check it out. Equivalent
    /// to `git checkout -b <name> [<start>]` (or `-B` with `force`).
    @discardableResult
    public func checkoutNewBranch(
        name: String,
        startPoint: String = "HEAD",
        force: Bool = false
    ) async throws -> CheckoutBranchOutcome {
        try await withRepository { repo in
            // Resolve start-point to a commit.
            var startObject: OpaquePointer?
            try check(git_revparse_single(&startObject, repo, startPoint))
            defer { git_object_free(startObject) }

            var startOID = git_object_id(startObject)?.pointee ?? git_oid()
            var startCommit: OpaquePointer?
            try check(git_commit_lookup(&startCommit, repo, &startOID))
            defer { git_commit_free(startCommit) }

            // Detect whether the branch existed beforehand so we can
            // report `Switched to a new branch` vs `Switched to and
            // reset branch`. With force=false libgit2 errors on
            // duplicate; with force=true it overwrites.
            let alreadyExisted: Bool = {
                var existing: OpaquePointer?
                let rc = git_branch_lookup(&existing, repo, name, GIT_BRANCH_LOCAL)
                if rc == 0 { git_reference_free(existing); return true }
                return false
            }()
            if alreadyExisted && !force {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "a branch named '\(name)' already exists")
            }

            // Create (or force-replace) the branch ref.
            var newBranch: OpaquePointer?
            try check(git_branch_create(&newBranch, repo, name, startCommit, force ? 1 : 0))
            defer { git_reference_free(newBranch) }

            // Check out the start-point's tree + point HEAD at the new branch.
            var coOpts = git_checkout_options()
            try check(git_checkout_options_init(&coOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            coOpts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)
            try check(git_checkout_tree(repo, startObject, &coOpts))

            if let refName = git_reference_name(newBranch) {
                try check(git_repository_set_head(repo, refName))
            }

            return alreadyExisted
                ? .resetExisting(name: name)
                : .createdNew(name: name)
        }
    }

    /// `git checkout -- <paths>`: restore the listed paths in the
    /// working tree to match the index (discards unstaged edits).
    public func checkoutPaths(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await withRepository { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }

            var copies: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
            defer { for c in copies { free(c) } }
            try copies.withUnsafeMutableBufferPointer { buf in
                var opts = git_checkout_options()
                try check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
                opts.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue)
                opts.paths = git_strarray(strings: buf.baseAddress, count: buf.count)
                try check(git_checkout_index(repo, index, &opts))
            }
        }
    }

    /// `git checkout <ref> -- <paths>`: restore listed paths from
    /// `ref`'s tree into BOTH the index and working tree (real git
    /// updates the index in this form).
    public func checkoutPaths(_ paths: [String], from ref: String) async throws {
        guard !paths.isEmpty else { return }
        try await withRepository { repo in
            var object: OpaquePointer?
            try check(git_revparse_single(&object, repo, ref))
            defer { git_object_free(object) }

            var tree: OpaquePointer?
            try check(git_object_peel(&tree, object, GIT_OBJECT_TREE))
            defer { git_tree_free(tree) }

            var copies: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
            defer { for c in copies { free(c) } }
            try copies.withUnsafeMutableBufferPointer { buf in
                var opts = git_checkout_options()
                try check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
                opts.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue)
                opts.paths = git_strarray(strings: buf.baseAddress, count: buf.count)
                try check(git_checkout_tree(repo, tree, &opts))
            }
        }
    }
}
