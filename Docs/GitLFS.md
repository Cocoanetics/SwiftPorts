# GitLFSKit — Git LFS

`GitLFSKit` is a pure-Swift port of [git-lfs](https://github.com/git-lfs/git-lfs)
(≥ 3.x, Go), tracked in issue #184. It is built up in sub-tasks; this page
describes the module surface as it stands and is extended by each one.

The reference is the upstream source — `lfs/pointer.go`, `lfs/lfs.go`,
`config/`, `fs/fs.go`, `lfsapi/endpoint_finder.go`, `lfshttp/endpoint.go`,
`lfsapi/auth.go`, `lfshttp/client.go`, `lfshttp/ssh.go`, `ssh/ssh.go`,
`tools/time_tools.go`, `creds/`. Behaviour and error texts
match it; nothing it doesn't have is added.

## Target

- Library product `GitLFSKit`, sources at `Sources/GitLFSKit/Lib/`.
- Depends on `SwiftGit`, `ShellKit`, swift-crypto `Crypto`, swift-http-types
  (`HTTPTypes`, `HTTPTypesFoundation`), `SSHKit` and GitKit's `CGitKit` config
  and pathspec APIs. No ArgumentParser.
- Builds on Android. `GitLFSKitTests` does not: it links swift-crypto's
  BoringSSL C++ target, so it is in `androidDroppedTargets` (see
  [Android.md](Android.md)).

## Downstream test server (`GitLFSTestSupport`)

The `GitLFSTestSupport` library product publishes the existing in-process
basic-transfer server from `Tests/GitLFSTestSupport`. Select it only in a
consumer's test targets, alongside the package's normal SwiftPorts dependency:

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        .product(name: "GitLFSTestSupport", package: "SwiftPorts"),
    ]
)
```

SwiftPM does not enforce test-only products. Keeping this dependency in test
targets avoids linking the server and its NIO/Crypto dependencies into the app.
The product and target are excluded on Android by the existing manifest filters;
`GitLFSKit` remains available there.

Use ordinary `import GitLFSTestSupport`. `LFSTestServer.start()` binds
`127.0.0.1` on an ephemeral port; `endpoint` is the LFS API root and `port` is
the assigned port. Call `await server.shutdown()` when finished, or use
`try await LFSTestServer.withServer { server in ... }` to shut down on both
return and throw. `store(_:oid:)` seeds bytes under their SHA-256 object id,
`bytes(for:)` reads stored objects, `inject(_:)` arms an `LFSTestFault` (for
example `.putStatus(oid: oid, code: 422)`), and `requests()` returns the recorded
requests and responses. No system Git, git-lfs, or external LFS service is needed
to use the server.

`Tests/Fixtures/GitLFSPublicConsumer` is a separate SwiftPM package that selects
this product only from its test target and checks the public API without
`@testable` or SPI. Its server tests run in the macOS, Linux, and Windows CI jobs.
Lifecycle checks establish native TCP connections before shutdown and require
connection refusal afterward, independently of HTTP responses or timeouts.
From the repository root, run it with a scratch directory outside the checkout:

```sh
swift test --package-path Tests/Fixtures/GitLFSPublicConsumer --scratch-path /tmp/SwiftPorts-LFSConsumer
```

## Pointer (`Pointer/`)

| Swift | git-lfs |
|-------|---------|
| `Pointer(oid:size:extensions:)` | `NewPointer` — latest version, `sha256`, canonical |
| `Pointer.empty` | `EmptyPointer` (the empty file; encodes to nothing) |
| `pointer.encoded` | `Pointer.Encoded()` — `version …\n`, `ext-<n>-<name> sha256:<oid>\n`…, `oid sha256:<oid>\n`, `size <n>\n` |
| `Pointer.decode(_ data:)` | `DecodePointer` / `DecodeFrom` — looks at the first 1024 bytes only, sets `canonical` |
| `Pointer.decode(fileAt:)` | `DecodePointerFromFile` — regular files under 1024 bytes; the path goes through `Shell.authorize` |
| `PointerExtension` | `PointerExtension` |
| `PointerError` | the errors `lfs/pointer.go` returns; `description` is git-lfs's text, `isNotAPointer` is `errors.IsNotAPointerError` |
| `Pointer.blobSizeCutoff`, `.v1Aliases`, `.latestVersion`, `.emptyObjectSHA256` | `BlobSizeCutoff`, `v1Aliases`, `latest`, `fs.EmptyObjectSHA256` |

Acceptance rules, as upstream:

- The data must mention `git-media`, `hawser` or `git-lfs`, else
  `Pointer file error: invalid header`.
- Surrounding white space is trimmed; lines split on `\n` (a `\r` before it is
  dropped); blank lines are skipped.
- Keys come in the order `version`, `oid`, `size`. Any other key that isn't
  an extension (`\Aext-\d-\w+`) fails with `pointer parsing: Expected key
  <due>, got <key>` — prefixed `Pointer file error: ` when `version` was due.
  So does a repeated key. A line after `size` is `Pointer file error: extra
  line: …`.
- `version` must be one of `http://git-media.io/v/2`,
  `https://hawser.github.com/spec/v1`, `https://git-lfs.github.com/spec/v1`;
  `oid` is `sha256:` and 64 lowercase hex digits; `size` a non-negative
  integer (`invalid size: "<value>"`, Go-quoted).
- Extensions are sorted by priority and re-encoded in that order; two with
  the same priority fail with `duplicate priority found: <n>`.

The texts are checked against `git lfs pointer --pointer=<file>` by the
oracle suite.

## Local store (`Store/`)

`LocalStore` is git-lfs's `fs.Filesystem` for one repository:

| Swift | git-lfs |
|-------|---------|
| `LocalStore.open(_ client:)` | `config.Filesystem()` — `client.commonDir()` (`git rev-parse --git-common-dir`) and `lfs.storage` |
| `LocalStore(gitStorageDirectory:storage:)` | `fs.New` — `lfs.storage` absolute as is, relative against the common dir, else `lfs` |
| `storageDirectory` | `LFSStorageDir` |
| `objectsDirectory`, `temporaryDirectory`, `incompleteDirectory` | `<lfs dir>/objects`, `/tmp`, `/incomplete` |
| `objectPathname(_:)` | `ObjectPathname` — `objects/<oid[0:2]>/<oid[2:4]>/<oid>`, the null device (`/dev/null`, `NUL` on Windows) for the empty object |
| `objectPath(_:)` | `ObjectPath` — makes the directory; `too short object ID: "<oid>"` |
| `objectExists(_:size:)` | `ObjectExists` |
| `makeTemporaryFile()` | `lfs.TempFile` |
| `insert(temporaryFile:oid:)` | the transfer adapters' verify + `tools.RenameFileCopyPermissions` |
| `store(_:oid:)` | a temp file in `tmp/`, then `insert` |
| `LocalStoreError` | `expected OID <oid>, got <actual> after <n> bytes written`, `cannot replace …`, … |

Because the store hangs off the common dir, every linked worktree shares the
main repository's objects, as with git-lfs. A file whose SHA-256 isn't the
OID it claims is never renamed into `objects/`; like upstream, it is left
where it is. Every path is authorized through `Shell.authorize`.

`SwiftGit.GitClient.commonDir()` was added for this; it mirrors
`git rev-parse --git-common-dir` and nothing more.

## Filter registration (#230, part 1 of #192)

Hosts opt in once, before SwiftGit operations, with
`try GitLFSKit.installFilter()`; `try GitLFSKit.uninstallFilter()` removes
the process-wide `lfs` registration. The `git` executable installs it before
dispatch. Constructing a client or running `git lfs install` does not register
it: that command continues to write filter configuration and hooks.

The default attribute is `filter=lfs`. A configured, nonempty
`filter.lfs.process` enables both directions and takes precedence over
`filter.lfs.clean` and `filter.lfs.smudge`, including when process is empty.
When process is absent, clean and smudge enable their respective directions.
An optional unconfigured direction passes through. Required clean fails without
a command; Git's streamable checkout bypasses a driver only when all three
commands are absent. Configuring any command, including an empty value or a
clean-only command, selects in-core conversion and fails required checkout
without a working smudge command. Attributes that are absent, unset or select
another driver do not invoke LFS.

Clean hashes content incrementally into temporary storage, verifies and inserts
the object, then emits the canonical pointer. Existing pointers below the
1024-byte cutoff retain their original bytes; empty content remains empty.
Smudge probes at most 1024 bytes and streams local or downloaded content in
64 KiB chunks. Downloads use the basic transfer queue, endpoint selection,
authentication and remote fallback. Checkout and clone restore content and
leave status clean. Linked worktrees share objects through the common directory;
`lfs.storage` also applies during clone when configured before checkout through
the host's global or command configuration. Source-repository local settings
are not inherited by clones.

`--skip`, `GIT_LFS_SKIP_SMUDGE`, `lfs.fetchinclude` and `lfs.fetchexclude`
preserve pointers even when the content is already cached. Optional single-shot
smudge failures replay the original input. An optional process driver that exits
during delayed checkout still fails with status 1 and Git's external-filter
diagnostics after the other checkout paths have been restored; clone adds
`fatal: unable to checkout working tree` and exits 128.
Failed paths have their index stat cache invalidated before the error returns,
so the empty failed output remains visible as modified in status and diff.
Deferral is limited to explicit checkout and clone operations. Composite
operations such as stash pop and stash branch fail immediately, before the
stash can be dropped, so restoring object access allows the entry to be retried.
Required process-driver failures report the external-filter error before the
path-specific fatal. Required download failures report git-lfs's diagnostic
and fail checkout/clone with Git's fatal text and status 128; this is distinct
from standalone `git-lfs smudge`'s status 2. `lfs.skipdownloaderrors` suppresses
the failure and emits the canonical pointer; `GIT_LFS_SKIP_DOWNLOAD_ERRORS`
overrides it, including an explicit false value.

The filter streams retain only a pointer probe and one bounded I/O chunk, not
the full content. GitKit/libgit2 still buffer smudge **input** and add **output**;
normally both are small pointers. Status/diff hash the full worktree file and
can buffer that input inside libgit2. These limits are outside the stream's
memory guarantee. The integration regression generates a 64 MiB file one block
at a time, checks retained probe and I/O bounds, hashes the smudged output
incrementally, and verifies the staged pointer. Task cancellation releases
the clean stream's temporary file.

Another libgit2 limitation is failed-clone cleanup: it removes the destination
after an immediate checkout error, whereas Git retains it. Deferred optional
process-filter failures retain the destination. The failure oracle checks the
LFS diagnostic, Git fatal/warning text and exit status; it does not establish
parity for retaining a failed clone's repository.

Callback filesystem/network work uses ForgeKit's internal `BlockingBridge`.
SwiftGit supplies a revocable operation context with the calling shell,
credentials, environment configuration and include authorization. Its metadata
client opens separate handles at the filter source's git directory, including
clone destinations and linked worktrees, without taking another isolation turn.
It permits config, metadata, raw-blob and ref access, and rejects git mutations
and access after the outer operation returns. Borrowed input and downstream
filter output never cross the async bridge.

## Native GitKit host operations (#277)

Hosts that call `GitKit.Repository` directly (instead of going through
`SwiftGit.GitClient`) can still run with `GitLFSKit.installFilter()` active by
wrapping each synchronous native git transaction in
`GitLFSKit.withOperation(credentials:shell:_:)`:

```swift
try await GitLFSKit.withOperation(credentials: credentials, shell: shell) { operation in
    try operation.authorize(sourceURL)
    try operation.createRepository(at: cloneURL, using: { preparation in
        try Repository.clone(from: sourceURL, to: cloneURL, preparation: preparation)
    }, { repository in
        try operation.authorize(linkedURL)
        let worktree = try repository.worktreeAdd(
            path: linkedURL, branch: "review", startPoint: "HEAD",
            preparation: operation.preparation)
        _ = try worktree.status()
    })
}
```

`GitLFSKit.withOperation` takes one `Libgit2Turnstile` / `Libgit2Sandboxing`
isolation turn asynchronously, installs the revocable filter context on the
calling thread, and invokes the synchronous body once without blocking the whole
async scope on `BlockingBridge`. No repository needs to exist at entry.

libgit2's search paths and homedir are process-global: the operation applies
its shell's `HOME` / `XDG_CONFIG_HOME` / `GIT_CONFIG_*` for the body and puts
the previous values back when it ends (#288). A GitKit call made outside an
operation can see another thread's operation in progress, so with GitLFSKit
linked every GitKit call goes through one. git-lfs has no "no transfers, no
credentials" setting and neither does GitLFSKit: an embedder that wants one
passes a `CredentialProvider` that returns nothing, sets `GIT_LFS_SKIP_SMUDGE` /
`GIT_LFS_SKIP_PUSH` in the operation's shell, and refuses the transfer
commands itself.

`GitLFSKit.Operation` provides:

- `authorize(_:)` — authorizes additional filesystem destinations or resolved
  connection URLs through the enclosing shell's sandbox before native GitKit
  touches them.
- `preparation` (`RepositoryPreparation`) — creation-time preparation for
  GitKit 2.17.0+ APIs (`Repository.clone(..., preparation:)` and
  `Repository.worktreeAdd(..., preparation:)`). Installs the operation's
  `ConfigIncludePolicy`, `ShellSigner`, and effective configuration levels via
  GitKit's typed `Repository.addConfigFile(at:level:)` and
  `Repository.addConfigEntries(_:level:name:)` before the first checkout.
- `withRepository(at:_:)` — authorizes `directory`, opens and prepares an
  existing primary repository, linked worktree, branch-holder worktree, or
  submodule, and invokes `body` once.
- `createRepository(at:using:_:)` — authorizes `directory`, runs `create` once
  with a scoped `RepositoryPreparation`, prepares the returned handle if it was
  not already prepared via `RepositoryPreparation` (such as
  `Repository.initialize`), and invokes `body` once.

Late `[include]` / `[includeIf]` files are authorized on demand without
replaying host mutations or durable claim callbacks; a sandbox denial surfaces
directly and GitKit rolls back any aborted clone or worktree creation. Submodules
retain their own repository and `LocalStore` identity, while linked worktrees
keep private `config.worktree` settings distinct from their shared common-dir
LFS storage. Process-wide clean filtering covers staging as well as `status()`
and `diff(.workdirVsIndex)`. `Operation` and `RepositoryPreparation` are revoked
when `withOperation` returns, and task cancellation aborts in-flight bridged
transfers and cleans temporary store files before releasing isolation.

For native `Repository.push(remote:refspecs:...:beforeSending:)` (plural
refspecs overload, including `PushLeases`), call
`PrePushOptions().run(_:updates:at:terminal:)` inside `beforeSending`. It
borrows the enclosing push's isolation without reacquiring a turn, uses the
operation's credentials and selected remote (including temporary fork remotes
and push URLs), completes the upload before returning, and throws any nonzero
`LFSCommandResult` so remote refs are not updated.

`Tests/Fixtures/GitLFSPublicConsumer`'s `NativeOperationTests` target exercises
this public surface with only `GitKit`, `GitLFSKit`, `GitLFSTestSupport`, and
`ShellKit` (no `@testable` or SPI imports).

`withRepository`'s open and `body`, and `createRepository`'s `body`, run inside
GitKit's `Repository.withOperationConfiguration`, so the same effective
configuration levels and include policy also reach the submodule handles libgit2
opens internally during `status()` / `diff` ([GitKit #98](https://github.com/Cocoanetics/GitKit/issues/98)),
without writing anything to a repository's config. Creation itself relies on
`RepositoryPreparation` and inherits an enclosing body's configuration scope
when nested. The required GitKit 2.17.0 release rolls back initialization when
an include is refused during the new repository's own `git_repository_init`
open, including search-path configuration (`$HOME`, XDG, system) and inherited
operation levels ([GitKit #101](https://github.com/Cocoanetics/GitKit/issues/101),
[GitKit #103](https://github.com/Cocoanetics/GitKit/issues/103)). GitKit owns the
rollback: it removes the artifacts it created only while their identity and
contents still match, preserving pre-existing files and concurrent changes.
The public `nestedCreationIncludeDenial` acceptance test covers missing, empty
and occupied destinations, artifact cleanup and retry; `nestedCreationConfiguration`
checks first-checkout configuration and LFS content without persisting settings.
Cancellation is never an optional (`filter.lfs.required=false`) fallback: clean
and smudge rethrow it instead of passing content through. The public
`recursiveSubmodules` regression forces an unchanged CRLF file to be rehashed
with scoped `core.autocrlf=true`, not written to local config, and expects clean
enclosing `status()` and workdir `diff`.

## Commands (`git lfs`, #189)

`GitCommand` depends on `GitLFSKit` and registers `lfs`. Its ArgumentParser
adapters live in `Sources/SwiftGit/GitCommand/Subcommands/LFS/`; behavior lives
in the SDK's `Commands/` directory:

- `version`: `git-lfs/3.7.1 (SwiftPorts; <os> <arch>; swift <version>)`.
  The compatibility release is upstream 3.7.1; the implementation/runtime
  identity is deliberately SwiftPorts/Swift, as agreed for #189.
- `pointer`: generate (`--file`), inspect/compare (`--pointer`, `--stdin`), or
  check (`--check`, `--strict`, `--no-strict`). `LFSPointerOptions` streams
  file hashing, computes Git blob OIDs, and preserves upstream diagnostics
  and exit statuses, including silent check failures.
- `install`/`uninstall`: `FilterOptions` selects global, local, system, file,
  or worktree config, writes the upstream filter commands, and installs/removes
  standard hooks through `Hook`. Hook bytes and historical-script upgrades
  follow `lfs/hook.go`; foreign scripts require `--force` to replace.
  Relative `core.hooksPath` is relative to the worktree root, and default
  hooks live in the common Git directory for linked worktrees.
- `track`/`untrack`: `TrackOptions` edits `.gitattributes`, lists patterns
  (including JSON), expands attribute macros, handles nested attribute files,
  preserves track's line endings and untrack's LF rewrite, escapes patterns,
  and touches matching indexed files. Supports `--lockable`, `--not-lockable`,
  `--dry-run`, `--verbose`, `--no-excluded`, `--filename`, and `--no-modify-attrs`.
- `ls-files`: `LsFilesOptions` selects the index and HEAD, a ref tree, a
  two-ref range, all refs, or history with deleted files. With no positional
  arguments the index is scanned before `--all`, `--deleted`, or the HEAD
  tree; an explicit ref skips the index. Supports long OIDs, sizes, names
  only, debug and JSON output, and explicit include/exclude filters. Checkout
  markers compare the working file's size; JSON reports downloaded objects
  independently through `LocalStore`. Scanning rules are below.
- `status`: `StatusOptions` reports unpushed LFS objects for the current
  branch's remote-tracking ref, staged changes, and unstaged work-tree changes
  in human, porcelain (`-p`/`--porcelain`), and JSON (`-j`/`--json`) forms.
  `LFSStatus` is a thin ArgumentParser adapter in `GitCommand`; the SDK remains
  ArgumentParser-free. Status rules are below.

All filesystem paths go through `Shell.authorize`; production code does not
launch a system Git or git-lfs process. The hooks are scripts for real Git to
execute. Other LFS commands and lock-based file permission management remain
the separate sub-tasks described in #184.

Bare `git lfs` prints upstream's complete usage text, preceded by the port's
version, and succeeds. Unsupported subcommands receive git-lfs's diagnostic
and exit status 127. `git lfs --help` uses embedded usage text; it does not
launch the system Git's man viewer.

## `git push` and the pre-push hook (#234)

`git push` does the work of git-lfs's pre-push hook in-process, without
running the script, when the hook git would run is git-lfs's
(`Hook.lfsPrePush`): `pre-push` in the `install` hooks directory
(`core.hooksPath`, else `<common-dir>/hooks`), executable on Unix (present
on Windows), read through `Shell.authorize`, with a non-comment line running
`git lfs pre-push`, `git-lfs pre-push` or `git lfs push --stdin`. A foreign
or non-executable hook is not run, and the push goes ahead as without one.

The updates are those GitKit is about to send (its `beforeSending` push
callback, after git's fast-forward and lease rules, up-to-date refs left
out), handed to `PrePushOptions.run(_:updates:client:git:terminal:)`, the
same path `git lfs pre-push` reads from stdin, so `GIT_LFS_SKIP_PUSH` and
`lfs.allowincompletepush` apply as there. The upload's git reads run in
the push's libgit2 isolation, lent to them while the push waits on one
connection. A failed upload prints git-lfs's output, then
`error: failed to push some refs to '<url>'`, exits 1 and sends nothing.
`--no-verify` skips the upload.

## Transfers (`Transfer/`, #198)

`LFSTransferQueue(client:store:direction:remote:refName:progress:)` transfers
`[LFSBatchObject]` through the HTTP basic adapter. An empty remote selects the
download or upload remote. Duplicate OIDs transfer once, retaining the first
name and upload path. The callback receives `(direction, name, totalSize,
readSoFar, readSinceLast)`; presentation belongs to the caller.

The queue batches objects (default 100), sorts by descending size, and runs
eight workers by default. Worker 0 opens the authentication gate on the first
successful response. Downloads stream into `incomplete/<oid>.part`, resume
validated ranges, and enter `objects/` only after SHA-256 verification. Failed
downloads retain the part. Uploads stream from disk, preserve action headers,
detect content types with Go's 512-byte sniffing rules, and POST an optional
verify action. A missing action silently skips an already-present object.

`lfs.concurrenttransfers`, `lfs.transfer.batchSize`, `lfs.transfer.maxretries`
(eight retries after the first attempt), and `lfs.transfer.maxretrydelay`
(ten seconds) use their defaults for values below one. Backoff starts at
250 ms and doubles to the cap. Only 429 honors `Retry-After`, without a cap;
503 uses ordinary backoff. Expired actions return to the next batch.
`lfs.transfer.maxverifies` permits at least three verification attempts.
These settings are not permitted in `.lfsconfig`.

`lfs.<url>.contenttype` / `lfs.contenttype` defaults to true. Upload 422
prints git-lfs's suggestion to disable detection once, without retrying it.
`lfs.transfer.enablehrefrewrite` defaults to false; enabling it applies the
endpoint finder's URL aliases to action hrefs without appending `/info/lfs`.
Object requests use one auth attempt and one additional attempt for an
unauthenticated 401; authenticated actions use their supplied authorization.
Batch and general API authentication keep their existing retry behavior.

SSH/file transfer adapters, tus, and `lfs.transfer.maxretrytime` remain
outside this surface. Progress lines are formatted by `LFSProgressMeter`;
see Fetch and push below. `file://` retains the standalone-transfer hint
and missing-protocol error.

## Fetch and push (`Transfer/`, `Commands/`, #233)

`LFSClient.fetch` downloads the pointers `GitScanner` finds. Without
`--all`, each ref is that ref's tip tree (`scanTree`); an empty ref list is
the current branch. `--all` with no refs is `scanAll`, and `--all` with refs
is `scanRefs` of those refs and no excludes. `-I` / `-X` replace
`lfs.fetchinclude` / `lfs.fetchexclude` when the flag is present; otherwise
the config pair applies, each side on its own. `--all` refuses include and
exclude, and says when it ignores a configured pair. Objects already in
`LocalStore` are not requested. `--dry-run` still asks the batch API and
prints `fetch <oid> => <path>` without transferring. `--json` prints
`{"transfers": […]}` and suppresses the meter. There is no `--recent`,
`--prune`, or `--refetch`.

`uploadObjects(for:)` is what `git lfs push` and `pre-push` run. A zero
local OID (a delete) is skipped. A non-zero remote OID, and the
remote-tracking tips the remote still advertises, are excluded. An all-zero
remote OID excludes every `refs/remotes/<remote>/*` tip. The upload scan
does not apply a path filter. `--all` scans that history with no remote
exclusions. A missing local object fails with `Git LFS upload failed:`
unless `lfs.allowincompletepush` is set, which warns with
`Git LFS upload missing objects:` and still uploads what is present.
`--dry-run` prints `push <oid> => <path>` and does not contact the server
for the batch. `--object-id` uploads those store objects and does not scan
commits.

`GitCommand` registers `fetch`, `push`, and `pre-push`. `fetch` takes an
optional remote and then refs; with no arguments it fetches the current ref
from the download remote. `push` requires a remote. `--stdin` reads one ref
or OID per line and rejects any further argument. `pre-push` reads the
hook's four-field lines and accepts the remote URL the hook passes. `git
push` also uses this path when git-lfs's pre-push hook is installed (#234).

Before an upload of refs, `LFSLockVerifier` POSTs `/locks/verify`, matching
git-lfs 3.7.1. A 404 or 501 records `lfs.<url>.locksverify false` and
continues, with no diagnostic. Any other failure prints the locking-API
text; an enabled check also fails the command. When the server implements
locking and the setting is unset, the command prints the "consider
enabling" hint.

`LFSProgressMeter` writes
`Uploading LFS objects: 100% (n/n), X MB | Y MB/s, done.` and the download
twin to stdout, as git-lfs's tasklog does. Intermediate lines are padded
and end in `\r`, and only when stdout is a terminal or progress is forced
(`GIT_LFS_FORCE_PROGRESS` or `lfs.forceprogress`). The final `, done.` line
is written either way. Dry-run and `--json` do not print it. An object the
server already has is still counted in `(n/n)`. `GIT_LFS_PROGRESS`, when it
is an absolute path, receives one append-only line per transferred chunk.

`GitCommandLFSTransferOracleTests` compares that stdout, stderr (including
`/locks/verify` text), and status with system git-lfs 3.7.1. Each side gets
the same repository shape and its own `LFSTestServer`, so both see an empty
server. A push with one implementation followed by `fetch` in a fresh clone
with the other checks that the bytes arrived. The comparison is raw except
for the meter's speed field.

## Scanning (`GitScanner`, #205)

`GitScanner` walks one repository through the in-process `GitClient`.
`FilepathFilter` decides which paths are candidates before a blob is decoded.
An empty include list allows every path; any matching exclude rejects the
path. Patterns use git-lfs wildmatch `Contents` mode: matching a directory
also matches its children, a trailing slash is dropped, and `!` and `#` stay
literal rather than gitignore syntax. Matching is case-insensitive on Darwin
and Windows. `lfs.fetchinclude` and `lfs.fetchexclude` are a different
setting; `ls-files` does not read them.

A blob is a pointer only when it is smaller than `Pointer.blobSizeCutoff`
(1024 bytes) and `Pointer.decode` accepts it. Larger blobs and malformed
pointer text are skipped. A decoded size of zero is still returned by the
scanner and dropped when `ls-files` renders a line.

`scanTree` walks one tree depth-first and keeps every matching path, including
paths that share a blob. `scanIndex` emits cached diff destinations that
decode as pointers, then the ref tree for names that diff did not replace.
Staged deletions stay in that following tree walk. An unborn `HEAD` is an
empty tree. `scanRefs` walks included commits in rev-list order and drops
every blob OID reachable from the excluded commits, including a blob whose
path the filter hid. `scanAll` visits direct tree and blob refs first, then
one history walk of the remaining commits, and deduplicates by blob OID.

`ls-files` with no positional arguments always scans the index first, then
`--all` (`scanAll`), `--deleted` (defaulting to `HEAD`), or the `HEAD` tree.
`--all` wins over `--deleted`. An explicit ref skips the index and scans that
tree. Two arguments `A B` include `B` and exclude `A`. A single argument
`A..B` is that tree name, not a range. A name that does not resolve is
reported as git ls-tree's `Not a valid object name`. A resolved ref whose
blob is later missing keeps that scan error. `--all` with a ref, `--deleted`
with two refs, and a bare `--all` after `--` fail with status 2. Name
deduplication is off for `--all` and for a two-ref range, and on otherwise.
Checkout is whether the worktree file at the repository root, after following
symlinks, has the pointer's size. `LocalStore` answers only the debug and
JSON download field. An empty JSON result is `{"files": null}`. Paths stay
repository-relative from a subdirectory cwd. A bare repository has no
worktree, so checkout is false.

`GitCommandLFSLsFilesOracleTests` compares system `git lfs ls-files` and
`GitCommand` on one repository, the same working directory, and the same
isolated `HOME`, `XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL`, and
`GIT_CONFIG_SYSTEM`. `LFSSamePathOracle` snapshots and restores local config,
the index, and worktree metadata between the two reads. Stdout, stderr, and
status match exactly: nothing is sorted, rewritten, or reformatted. The only
normalization replaces a `git-lfs/<digits…>` line and a `git version` line,
and only when a command prints one. The suite runs only when the first token
of `git lfs version` is `git-lfs/3.7.1`. It does not call `LFSCommandFixture.compare`.

## Status (`git lfs status`, #206)

`StatusOptions` (`Sources/GitLFSKit/Lib/Commands/StatusOptions*.swift`) implements
git-lfs 3.7.1's `commands/command_status.go` over `SwiftGit.GitClient`, without
ArgumentParser or external processes. `LFSStatus` in `GitCommand` is a thin
adapter supporting `-p`/`--porcelain` and `-j`/`--json` and ignoring extra
positional arguments. `GitLFSKit` remains ArgumentParser-free and builds on
Android; `GitLFSKitTests` and `GitCommandTests` remain in `androidDroppedTargets`.

Status requires a work tree (`LFSRepository.open(client, workTree: true)`).
Outside a repository it writes `Not in a Git repository.\n` to stdout with
status 128; in a bare repository it writes
`This operation must be run in a work tree.\n` to stdout with status 128. Both
diagnostics apply before format selection (`--porcelain` and `--json` included).

### Tracking-ref resolution

In default (human) mode, status resolves `HEAD` (tolerating an unborn `HEAD` by
omitting the branch banner and pushed section). A detached `HEAD` prints
`On branch HEAD`. For a named branch, `trackingRef(branch:client:)` follows
git-lfs's `RemoteRefNameForCurrentBranch` using only fetch tracking
configuration:

- Read `branch.<name>.remote`; if absent or empty, omit the pushed section.
- Read `branch.<name>.merge`; strip a `refs/heads/` prefix if present,
  otherwise fall back to the local branch name (covering missing, empty,
  unqualified, and non-`refs/heads/` values such as `refs/tags/...`).
- Check `refs/remotes/<remote>/<trackingBranch>`; if it resolves, print
  `Objects to be pushed to <remote>/<trackingBranch>:` and scan
  `HEAD` excluding that ref via `GitScanner.scanRefs`, listing full 64-hex LFS
  OIDs (`\t<path> (<oid>)`).
- `branch.<name>.pushRemote` and `remote.pushDefault` are ignored.
- If the tracking scan fails after emitting some pointers (for example on a
  corrupt later Git blob), already-scanned pointers remain in stdout and the
  command exits with status 2 and `Could not scan for Git LFS objects: …` on
  stderr.

### Index scanning, pointer comparison and deduplication

`StatusOptions.scanIndex` uses typed full-OID `GitClient.diffIndex` records:

1. Check for unmerged index entries (stage != 0). Upstream `git.DiffIndex`
   runs `git update-index -q --refresh` before diffing, which exits 1 with
   `<path>: needs merge` lines on any conflict; `status` matches that by
   failing with status 2 after printing the human branch/pushed header (or
   with empty stdout in `--porcelain` / `--json`).
2. Run refreshed uncached `diff-index -M HEAD` (`cached: false, refresh: true`)
   before cached `diff-index --cached -M HEAD` (`cached: true`), sorted in raw
   UTF-8 byte order (even under `core.ignoreCase = true`) and without splitting
   `T` typechanges into cross-file renames. An unborn `HEAD` uses the empty
   tree baseline.
3. `comparePointers` compares each regular uncached work-tree change against
   its stage-zero indexed pointer by streaming the work-tree file's SHA-256
   directly without invoking a clean filter. Clean smudged LFS files are
   suppressed when they also match `HEAD`, or rewritten to their indexed pointer
   OID when staged ahead of `HEAD`. Corrected additions are re-paired against
   unpaired deletions using libgit2's 50% similarity threshold. Conflicted
   entries (no stage-zero entry) are never compared against conflict stages.
4. Cached entries are drained first, then uncached entries, deduplicating by
   `(oldOID, newOID, destination-or-source path)` bytes so a clean staged change
   reported by both diffs appears once under staged.
5. Paths are formatted with Git's C-style quoting (`core.quotepath`, defaulting
   to `true`) at the presentation boundary after raw-path pointer comparison,
   and joined as raw UTF-8 strings (without `URL` Unicode normalization).

### Output forms

- **Default (human)**: prints the branch banner and optional pushed section,
  then `Objects to be committed:` and `Objects not staged for commit:`. Paths
  are relativized against the current working directory (without quoting the
  prefix, matching upstream's `relativize`). Staged renames and copies print
  `<source> -> <destination>`; unstaged entries print `<source>`.
- **Porcelain (`-p`, `--porcelain`)**: takes precedence when combined with
  `--json`. Omits the branch banner and pushed section, visits unstaged entries
  before staged entries, deduplicates by destination-or-source path, and emits
  repository-relative paths using ` M <path>` for modifications,
  `<S>  <source> -> <destination>` for `R`/`C`, and `<S>  <path>` for other
  statuses (including ordinary tracked files).
- **JSON (`-j`, `--json`)**: emits `{"files":{...}}\n` (or `{"files":{}}\n`
  when empty) with repository-relative paths. Visits unstaged then staged,
  keeping an entry only when `blobInfoFrom` (its source side, or destination
  for additions whose `oldOID` is all zeros) classifies as `.lfs`. Staged
  entries overwrite unstaged entries for the same path key. Keys are sorted by
  raw UTF-8 bytes and strings apply Go's JSON/HTML escaping (`<`, `>`, `&`,
  `U+2028`, `U+2029`).

### Hash and annotation rules

`PointerScanner.annotation(_:name:repositoryRoot:)` classifies each status side
and `StatusOptions` formats the leading seven hex digits (`from -> to`, or just
`from` for status `A`):

- **Valid small pointer (`< 1024` bytes)**: `LFS: <7-hex>` using the pointer's
  target SHA-256.
- **Ordinary, malformed, or `>= 1024`-byte Git blob**: `Git: <7-hex>` using the
  SHA-256 of the blob's raw contents (not its Git SHA-1).
- **Zero destination OID**: streams the work-tree file at the repository root
  (following symlinks after `Shell.authorize`) and emits `File: <7-hex>`, or
  `File: deleted` when the path is absent or replaced by a directory.
- **Missing Git ODB object**: `?: <missing>` (corrupt Git blobs still fail).
- **Missing local LFS payload**: absent files under `.git/lfs/objects/` do not
  affect `git lfs status`, which reads only Git blobs and work-tree files.

### Status test and oracle coverage

- Non-oracle tests in `Tests/GitLFSKitTests/` run without `git-lfs` using
  `IsolatedLFSHost`, `LFSFixture`, `GitClient`, and direct SHA-256 expectations:
  `PointerScannerTests`, `StatusOptionsTests`, `StatusRenderingTests`, and
  `StatusPathQuotingTests`. CLI flag parsing lives in `GitCommandLFSParsingTests`.
- `GitCommandLFSStatusOracleTests` (with `GitCommandLFSStatusOracleTests+Matrix`)
  reuses `Support/LFSSamePathOracle.swift` on macOS and Linux, gated on
  `LFSSamePathOracle.isAvailable` (exact `git-lfs/3.7.1`). It compares complete
  stdout, stderr, and exit status at the same path and environment with no path,
  line-order, JSON, or whitespace normalization across human, porcelain, and
  JSON forms, with one exception. On a merge conflict, upstream's
  `error running <git> 'update-index' …` stderr names the absolute path of the
  host git binary that its `subprocess` ran (for example
  `/usr/bin/git`, or git's libexec `git` when it is launched through
  `git lfs`). The in-process port does not run a git binary and prints `git`.
  The oracle replaces only that executable token before comparing. This is an
  accepted limitation: conflicted-index stderr is exact except for the
  executable path. The forms cover tracking refs (none, missing, renamed merge,
  fallback merge, competing `pushRemote`/`remote.pushDefault`),
  detached/unborn HEAD, clean smudged/pointer-only/permission-only states,
  ordinary tracked and untracked files, same-size edits, partially staged changes and baseline reversions,
  LFS↔Git transitions, deletions and file-to-directory replacements, renames,
  symlink type changes, merge conflicts, missing Git blobs versus missing local
  LFS payloads, partial tracking corruption, subdirectory invocation, C-quoted
  paths, Unicode sorting and Go JSON escaping, and bare/outside-repository
  diagnostics.

## Environment report (`git lfs env`, #207)

`LFSEnv.run(client:)` returns the 3.7.1 configuration report without network
or SSH authentication. The thin `LFSEnvCommand` only creates the GitClient and
emits its result. The SDK remains ArgumentParser-free.

The report starts with `LFSVersion.string`, the shared `PortVersion.gitLine`
(the first line of `git version`), and a blank line. Endpoints retain config
order, each immediately followed by its optional `  SSH=user@host:path` line.
`environmentEndpoints()` is a dictionary projection for existing consumers;
it is not the env renderer. Download and upload access use their respective
configured remotes, without download autodetection.

Paths use the working-tree root, worktree Git dir, common Git dir, and
`LocalStore`'s storage layout. Linked worktrees share storage; relative
`lfs.storage` is relative to the common dir. Outside a repository the Git and
working directories are empty, while the default storage paths remain relative
(`lfs`, `lfs/objects`, `lfs/tmp`), matching `fs.New`. Alternate references list
existing sibling `lfs/objects` directories, first from
`GIT_ALTERNATE_OBJECT_DIRECTORIES`, then `objects/info/alternates`. As in 3.7.1,
relative alternate paths are checked against cwd, including file entries.

The fixed settings block includes fetch/prune options, access modes and sorted
transfer names. These are readouts of deferred capabilities: no queue, adapter,
fetch or prune operation is created. Tus is upload-only, custom transfer
directions restrict their name lists, and basic-only reports just `basic`.
Skip-download-errors is the OR of the environment and config booleans;
`lfs.fetchrecentremoterefs` controls `FetchRecentRefsIncludeRemotes`.
Optional fetch patterns and extension lines precede the `GIT_*` section.
Inherited variable names follow the process environment block, taking values
from Shell; Shell-only names follow in its enumeration order. Values are never
path-normalized. The final three filter values use Go quoting, including `""`
when absent. Existing unsafe `.lfsconfig` warnings and env's config-clash
warnings go to stderr.

`LFSEnvReportTests` runs without git-lfs. `LFSEnvOracleTests` uses the pinned
3.7.1 git-lfs binary and the built git executable at the same repository path, with an
identical isolated HOME/XDG/config, cwd and ordered `posix_spawn` environment.
It compares raw ordered stdout, stderr and status, replacing only the two
version lines. It explicitly checks non-alphabetical `GIT_*` input order and
never sorts or rewrites output. System Git creates the fixtures; env invokes
git-lfs directly because system Git may reorder envp before dispatching an
external command, defeating the explicit input-order check. Oracle remote cases use origin plus at most one
other remote because upstream enumerates its remaining remotes through a Go
map; direct tests lock config order for larger lists and non-origin tracking.
Extensions are also a Go map upstream, so the raw oracle uses one extension.
Process oracles skip at runtime without git-lfs on macOS/Linux; Android target
gating is unchanged.

## Endpoints and credentials (`Endpoint/`, `HTTP/`)

`LFSEndpointFinder` is git-lfs's `lfsapi.EndpointFinder`. `LFSClient` sends
one request the way `lfsapi.Client.DoWithAuth` does.

| Swift | git-lfs |
|-------|---------|
| `LFSEndpointFinder.init(_:)` | reads `.lfsconfig` (work tree, else the index, else `HEAD`; bare repos read `HEAD` only) then `GitClient.configLines()`, so git config wins. A `.lfsconfig` that does not parse prints `Error reading \`git config\`: …` and both sources are dropped. Only git-lfs's safe keys are kept |
| `endpoint(operation:remote:)` | `Endpoint` — upload tries `lfs.pushurl` then `lfs.url`; a named remote tries `remote.<name>.lfspushurl` (upload) then `lfsurl`; otherwise the remote's `pushurl` (upload) or `url`, rewritten with `url.<base>.insteadOf` / `pushInsteadOf` and, for a clone URL, `/info/lfs`. `ssh` and scp-style remotes also fill `LFSSSHMetadata` (`user`, `host`, `port`, `path`, `userAndHost`). `file://` is left alone |
| `downloadRemote()` / `uploadRemote()` | `config.Remote` / `PushRemote`. `lfs.remote.autodetect` applies only to the download remote. `candidateRemotes(operation:)` is the `lfs.remote.searchall` list (git-lfs reads the flag and has no caller) |
| `environmentEndpoints()` | the `Endpoint=` / `Endpoint (<remote>)=` lines of `git lfs env`. The bare `Endpoint` line is printed only when the selected remote is `origin`. Autodetect is not applied |
| `access(for:)` / `setAccess(_:)` | `lfs.<url>.access`. `private` is `basic`. `none` unsets the key. The URL in the key has its userinfo removed |
| `LFSClient.init(git:credentials:session:)` | `~/.netrc` from `Shell.env("HOME")` (`_netrc` on Windows), then the caller's `CredentialProvider` — the same callback `GitClient` takes. `GitCommand` passes `CommandContext.envCredentialProvider()` |
| `data(for:operation:remote:)` | `http.<url>.extraHeader` on every attempt, `User-Agent: git-lfs`. Credentials are added only when access is neither `none` nor `negotiate`, in the order URL-embedded, netrc, cache, provider. A 401 writes the next mode (`basic` when the server doesn't say) and retries. `file://` prints git-lfs's hint and fails with `missing protocol` |

Negotiate HTTP authentication is not implemented: the request is sent without
a Basic header.

## SSH authentication (`HTTP/`, #188)

`LFSClient.ssh` is an async `LFSSSHResolver`, corresponding to git-lfs's SSH
resolver and cache. `resolve(_:method:)` takes the endpoint from the finder
and returns `LFSSSHAuthResponse` (`href`, `header`, `expires_at`, `expires_in`).
The endpoint's operation wins over the HTTP method; otherwise `GET`/`HEAD`
download and other methods upload. A batch request builder uses a nonempty
`href` instead of the guessed HTTP base URL, and sets the returned headers.
`LFSClient.data(for:operation:remote:)` also applies this authentication to
requests built with the original endpoint URL, preserving the request suffix
and body.
Requests to a different base URL do not receive these SSH-provided headers.

For SSH and scp-style remotes, the resolver opens SSHKit's exec channel for
`git-lfs-authenticate <path> download|upload`, without a subprocess or a
semaphore bridge. Paths use upstream's `subprocess.ShellQuoteSingle`: plain
shell words are bare; other paths are single-quoted with embedded quotes
escaped. This follows upstream's corrected quoting in `ssh/ssh.go` rather
than the unquoted interpolation in 3.7.1.
`SSHClient.connect(host:port:user:configPath:commandLineOptions:requireConfigFile:)`
is shared with `GitKitSSHTransportProvider`; it loads `~/.ssh/config`, resolves
aliases, URL overrides, identities, known_hosts and StrictHostKeyChecking
through the existing SSHKit APIs. GitKitSSH retains its existing behavior.

Authentication is cached separately for download and upload and for each SSH
destination, port and repository path. Expiration uses the command start time;
nonzero `expires_in` takes precedence over `expires_at`. A response without
either lifetime uses `lfs.defaulttokenttl` (negative values become zero),
otherwise it does not expire. Cached responses refresh five seconds early.
`lfs.cachecredentials=false` disables the cache. Failed commands or JSON
decoding are retried `max(0, lfs.ssh.retries) + 1` times (default six attempts)
and are never cached. A remote failure reports trimmed stderr followed by
`: exit status <n>` (or just the exit status when stderr is empty). Exit status
127 and server responses identifying `git-lfs-authenticate` as unavailable
instead fall back immediately to the guessed HTTPS endpoint.

URL-specific `lfs.<url>.sshtransfer` overrides `lfs.sshtransfer`. Only unset,
`negotiate` and `never` permit authentication; other values, including
`always`, fail with upstream's `git-lfs-authenticate has been disabled by
request`. The pure `git-lfs-transfer` protocol remains out of scope.

SSH command precedence follows git-lfs: `GIT_SSH_COMMAND`, then `GIT_SSH`,
then `core.sshCommand`, then `ssh`. For an `ssh` or Windows `ssh.exe` command,
`-F`, `-i`, `-o`, `-p` and `-l` become SSHKit configuration directives,
preceding URL and config values. `GIT_SSH_VARIANT` overrides `ssh.variant`;
PuTTY/Plink variants,
custom SSH executables/wrappers and other command-line options fail
explicitly because SSHKit cannot run an external SSH implementation. SSHKit's
existing key algorithm and configuration limits still apply (see [SSH.md](SSH.md)).

At the examined main commit `b6c9639`, #187's batch client and HTTP test server
are not present. The resolver API and the existing HTTP request path are wired;
the assertion through #187's batch client/server remains open for that work.


## Tests

### Temporary Windows upload transport (#243)

Windows PUT bodies use the Swift 6.4 SDK's static `libcurl.lib` (Schannel),
driven by curl's polling loop. This works around
[swift-corelibs-foundation #5532](https://github.com/swiftlang/swift-corelibs-foundation/issues/5532):
URLSession loses write readiness after a socket-buffer fill. Known-length
file/Data PUTs stall before a response even when the receiver drains every
chunk; fixing the separate stream probe's conflicting framing cannot fix
that runtime driver. The adapter preserves Content-Length and explicit
Expect headers rather than forcing chunked encoding.

This is temporary: remove both Windows switches and `CLFSCurl` when the
toolchain fixes #5532. Only Windows compiles/uses the adapter; macOS, Linux,
Android and iOS retain URLSession. No curl package, source, DLL loading or
alternate TLS implementation is added. The manifest resolves the SDK's
static curl, zlib and Brotli archives; Schannel uses Windows certificate trust.
LFSClient still prepares credentials and handles the 401 resend, while the
adapter keeps configured headers/cookies, HTTP(S) proxy settings (or curl's
environment defaults), redirects and bounded reads. Redirects follow the
URLSession method rules (303 to GET, 307/308 retaining PUT); curl does not
forward authorization to another origin.

The old file reader queried `streamError` after opening successfully: Swift 6.4.2's
[corelibs getter](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.2-RELEASE/Sources/Foundation/Stream.swift#L147-L149)
force-unwraps the absent underlying error after a successful open. Querying it
unconditionally trapped in Windows `parallelTransfers`. File uploads now own
independent `CreateFileW` handles with read/write/delete sharing, obtain their
length through `GetFileSizeEx` and read at most 64 KiB through `ReadFile` per
callback. Redirect rewinds use `SetFilePointerEx` after validating the offset
against the known length. Size validation and the 512-byte Content-Type sniff
also use that native reader, before the upload starts. No Foundation file handle
or stream is used for file bodies. Explicit stream bodies retain their bounded
InputStream reader.
The Windows curl regression uploads empty and 1 MB files concurrently from the
same path and checks exact bodies, framing and bounded progress. On Windows,
the in-process NIO fixture (`LFSTestServer` and `LFSWireClient`) also sets
`maxMessagesPerRead = 1` because `swift-nio` 2.105.0's `Windows.recv` throws
`IOError(winsock: WSAEWOULDBLOCK)` instead of returning `.wouldBlock(0)` when a
second speculative read runs in the same `WSAPoll` readiness turn.

`Tests/GitLFSKitTests/`:

- `LFSURLSessionUploadTests` — 1 MB file/Data/stream PUTs to the NIO fixture,
  including 200/503/401, cancellation, and an idle response timeout. Explicit
  framing assertions check the received headers and complete body. Windows
  exercises the temporary static curl path; other platforms use URLSession.
- `PointerTests` — round-trips, the empty file, the 1024-byte boundary,
  extension ordering, every rejection with its text.
- `LocalStoreTests` — store paths in a plain repository, a linked worktree and
  with `lfs.storage`; verified writes; a corrupt temp object is rejected and
  never lands in `objects/`.
- `LFSOracleTests` (macOS / Linux) — our pointer bytes against
  `git lfs pointer --file` and `git lfs clean`, rejection texts against
  `git lfs pointer --pointer`, store locations against `git lfs env`. Runs the
  system `git` / `git-lfs` in an isolated HOME / XDG / global config
  (`Support/LFSOracle.swift`) and is skipped when `git lfs version` isn't on
  `PATH`.
- `CommandBehaviorTests` — pointer checks, file-scoped filter installation,
  and hook conflict protection without a system git-lfs dependency.
- `LFSFilterIntegrationTests` — direct SwiftGit add, local/server checkout and
  clone, immediate clean status, linked/shared storage, credential retry,
  bounded streaming and cancellation cleanup. Nested under the serialized
  registration suite. On macOS/Linux, concurrent isolated subprocesses launch
  the built `git` executable to prove startup registration, with hard deadlines
  and file-backed output to prevent pipe deadlocks.
- `LFSFilterOracleTests` (macOS/Linux, skipped unless git-lfs 3.7.1 is present)
  — subprocess comparisons on the same repository: exact staged pointer bytes
  and blob OIDs, attribute/command gating, process precedence, skip/include/
  exclude, malformed input, remote selection and search-all fallback, download
  diagnostics, checkout/clone fatal text and exit status, optional failure and
  download-error suppression. Uses `GitLFSTestSupport`'s loopback server,
  including a successful batch with no action and no local object. Oracle
  operations never change the test runner's process-wide filter registration.
- `GitCommandLFSParsingTests` — command and flag parsing, gated like the other
  `GitCommandTests` using `commandTestPlatforms`.
- `GitCommandLFSOracleTests` and `GitCommandLFSConfigOracleTests` — twin
  repositories compare command output, exit status, attributes, hook bytes,
  and config values. Only environment-specific absolute paths and the agreed
  version identity are normalized. Config entries are sorted because upstream
  installs them by iterating Go maps. Skipped when git-lfs is unavailable.
  CI installs the checksum-verified 3.7.1 reference on macOS and Linux. For local
  command-oracle runs, put Git LFS 3.7.1 on `PATH`; newer releases change exact
  help and diagnostic text.
- `EndpointResolutionTests` — `lfs.url`, `remote.<name>.lfsurl`, upload
  `pushurl` / `lfspushurl`, `insteadOf` / `pushInsteadOf`, and `https` / `ssh`
  / scp / `file://` derivation (nested paths, ports, a trailing `.git`).
- `LFSConfigSourceTests` — `.lfsconfig` against git config, the index and
  `HEAD` (and a bare repo's `HEAD`), access modes, remote selection,
  autodetect, `searchall`, `FETCH_HEAD`, and `extraHeader`.
- `LFSCredentialTests` — netrc and a password embedded in the URL, and a
  401 → credential → retry against a `URLProtocol` mock.
- `LFSSSHResolverTests` / `LFSSSHCommandOptionsTests` — response parsing,
  absolute/relative expiry, default TTL, operation caching, retries, command
  quoting, SSH command precedence and URL-specific `sshtransfer`.
- `LFSCredentialTests.sshAuthentication` (macOS / Linux, skipped without
  `sshd`) — a throwaway OpenSSH server with a fake `git-lfs-authenticate`
  verifies config alias resolution, identities and known_hosts, path quoting,
  separate download/upload tokens, cached authentication, and stderr failures.
  A `URLProtocol` recorder asserts the request's overridden URL and headers.
- `LFSEndpointOracleTests` (macOS / Linux) — `Endpoint=` / `Endpoint (<remote>)=`
  from `git lfs env` against `environmentEndpoints()`, skipped without `git-lfs`.
- `GitCommandLFSLsFilesOracleTests` (macOS / Linux) — `ls-files` stdout, stderr,
  and status against system git-lfs on one repository
  (`Support/LFSSamePathOracle.swift`). Only a `git-lfs/` version line and a
  `git version` line are normalized. Skipped unless `git lfs version` starts
  with `git-lfs/3.7.1`.
- `PointerScannerTests`, `StatusOptionsTests`, `StatusRenderingTests`, and
  `StatusPathQuotingTests` — non-oracle `git lfs status` blob annotations,
  pointer-aware work-tree comparison, rename re-pairing, tracking-ref
  resolution, human/porcelain/JSON rendering, and C-style path quoting without
  a `git-lfs` binary.
- `GitCommandLFSStatusOracleTests` (macOS / Linux) — `status`, `--porcelain`,
  and `--json` same-path oracle matrix against pinned `git-lfs/3.7.1` via
  `Support/LFSSamePathOracle.swift`, with no normalization beyond version lines
  where printed and the host git path in the merge-conflict `update-index`
  diagnostic (see Status test and oracle coverage). Skipped unless `git lfs version` starts with `git-lfs/3.7.1`.
- `GitCommandLFSTransferOracleTests` (macOS / Linux) — `fetch` / `push`
  stdout, stderr, and status on one repository shape, each side against its
  own `LFSTestServer`. Covers `--all`, `--object-id`, `--dry-run`, `--json`,
  an invalid remote, and `--stdin` misuse, plus a push then a fetch from a
  fresh clone in both directions. Only a meter line's speed field is
  normalized. Same `git-lfs/3.7.1` gate.
