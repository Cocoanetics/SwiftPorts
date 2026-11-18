# GitLFSKit — Git LFS

`GitLFSKit` is a pure-Swift port of [git-lfs](https://github.com/git-lfs/git-lfs)
(≥ 3.x, Go), tracked in issue #184. It is built up in sub-tasks; this page
describes the module surface as it stands and is extended by each one.

The reference is the upstream source — `lfs/pointer.go`, `lfs/lfs.go`,
`config/`, `fs/fs.go`, `tools/`. Behaviour and error texts match it; nothing
it doesn't have is added.

## Target

- Library product `GitLFSKit`, sources at `Sources/GitLFSKit/Lib/`.
- Depends on `SwiftGit`, `ShellKit`, swift-crypto `Crypto`, swift-http-types
  (`HTTPTypes`, `HTTPTypesFoundation`) and `SSHKit`. No ArgumentParser.
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
