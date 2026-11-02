# Windows support

SwiftPorts compiles a subset of its targets on Windows (Swift 6.4.2, MSVC
toolchain via [SwiftyLab/setup-swift](https://github.com/SwiftyLab/setup-swift)).
The CI matrix's `build-windows` job reflects exactly what works today.

## What builds on Windows

| Target          | Kind         | Status |
|-----------------|--------------|--------|
| `ForgeKit`      | library      | ✅ |
| `ZipKit`        | library      | ✅ |
| `ZipCommand`    | library      | ✅ |
| `UnzipCommand`  | library      | ✅ |
| `GitHub`        | library      | ✅ |
| `GitLab`        | library      | ✅ |

These are built explicitly via `--target` flags in the workflow.

## What doesn't build on Windows

Everything that transitively depends on libgit2:

| Target          | Kind         | Blocker |
|-----------------|--------------|---------|
| `SwiftGit`      | library      | depends on `libgit2` C target |
| `GitCommand`    | library      | depends on `SwiftGit` |
| `git`           | executable   | depends on `GitCommand` |
| `GhCommand`     | library      | depends on `SwiftGit` |
| `gh`            | executable   | depends on `GhCommand` |
| `GlabCommand`   | library      | depends on `SwiftGit` |
| `glab`          | executable   | depends on `GlabCommand` |
| `zip`, `unzip`  | executables  | not currently exercised on Windows CI |

### Root cause: libgit2 SwiftPM packaging

The `libgit2` dependency is sourced from
[`ibrahimcetin/libgit2`](https://github.com/ibrahimcetin/libgit2) (1.9.x).
Its `Package.swift` has two branches:

- `#if os(macOS)` — Apple-specific `cSettings` (CommonCrypto, SecureTransport,
  iconv, `GIT_NSEC_MTIMESPEC`).
- `#else` — assumes POSIX/Glibc (defines `_GNU_SOURCE`, `GIT_NSEC_MTIM`,
  `GIT_RAND_GETENTROPY`, etc., links `z`/`dl`/`pthread`).

There is no Windows branch. The `#else` arm catches Windows by accident and
the build immediately fails:

```
.build/checkouts/libgit2/src/util/win32/w32_util.h:83:3:
  error: GIT_NSEC defined but GIT_NSEC_WIN32 not defined

.build/checkouts/libgit2/src/util/posix.h:199:11:
  fatal error: 'poll.h' file not found
```

Compounding the issue, `excludedPaths` in that `Package.swift` lists
`src/util/win32` as "Windows-specific files (never used on Unix-like
systems)" — but it's excluded for **every** platform, including Windows.
So even if the Win32 defines were set, the source files implementing them
are missing from the SwiftPM build.

Fixing this needs upstream work in `ibrahimcetin/libgit2`'s `Package.swift`:

1. Add an `#elseif os(Windows)` branch that includes `src/util/win32` and
   the Win32 hash backend, defines `GIT_NSEC_WIN32` (and other Win32
   variants of the time/entropy/qsort macros), drops the POSIX-only
   `linkedLibrary` calls, and links the Win32 import libraries
   (`Ws2_32`, `Crypt32`, `Rpcrt4`, `Winhttp`, …).
2. Pick a Windows TLS/HTTPS backend — likely `WinHTTP` (`GIT_HTTPS_WINHTTP`)
   since SecureTransport / OpenSSL aren't a fit.
3. Pick a Windows hash backend — likely `Win32` (`GIT_SHA1_WIN32`,
   `GIT_SHA256_BUILTIN`).

Once that lands (or once we maintain our own libgit2 SwiftPM fork), the
`build-windows` workflow can drop its `--target` filter and build the full
matrix.

## CI workflow

`.github/workflows/swift.yml` → `build-windows`:

- Installs `zlib` via vcpkg (`x64-windows-static-md`) for `GzipKit`'s
  inflate/deflate path and for libarchive's gzip filter (via
  `marcprux/swift-archive`).
- `swift build` with explicit `--target` flags for the library list above.
- No `continue-on-error` — failures actually break CI.
- No `swift test` step — most test targets pull in libgit2-using code via
  `GhCommand` / `SwiftGit`. Re-add once the libgit2 packaging supports
  Windows.

## Adding a new Windows-buildable target

If you add a library target that doesn't transitively depend on `SwiftGit`
or libgit2, append it to the `--target` list in `build-windows`. Run the
job once to confirm the closure stays clean.

If you add a target that does depend on libgit2, leave it out of the
Windows list — the rest of the matrix still covers it.
