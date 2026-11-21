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

SSH/file transfer adapters, tus, progress-line formatting, and
`lfs.transfer.maxretrytime` remain outside this surface. `file://` retains
the standalone-transfer hint and missing-protocol error.
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

`Tests/GitLFSKitTests/`:

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
