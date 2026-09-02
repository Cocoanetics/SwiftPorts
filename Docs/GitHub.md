# GitHub port (`gh`)

Pure-Swift port of [`cli/cli`](https://github.com/cli/cli) (`gh`).
Targets a broad slice of the upstream surface — auth, repos, PRs,
issues, releases, projects (v2 GraphQL), workflows, runs, gists,
search, plus account-level admin.

## Targets

| Target / Product | Role |
|------------------|------|
| `GitHub` (lib)        | REST + GraphQL API client, OAuth device flow, Codable models, `RepositoryReference` parsing, `Configuration` + `ConfigurationResolver`, hosts.yml read/write. No ArgumentParser dependency. |
| `GhCommand` (lib)     | The whole AsyncParsableCommand subcommand tree. Importable across packages — SwiftBash extends `GhCommand` to register the entire `gh` surface as a Bash builtin. |
| `gh` (exec)           | Four-line `Entry.swift` wrapper. `@main` delegates to `GhCommand.main()`. |

Layout under `Sources/GitHub/{Lib,GhCommand,gh}/` per the SwiftPorts
umbrella convention (see [../AGENTS.md](../AGENTS.md)).

## Auth

```
gh auth login    [--web] [--clipboard]   OAuth device flow
gh auth status   [-h <host>] [--show-token]
gh auth logout   [-h <host>]
gh auth token    [-h <host>]             Print resolved token
```

`auth login --web` runs the device-code OAuth flow against
github.com (or `--hostname` for GitHub Enterprise). On approval, the
token lands in the macOS Keychain. `--clipboard` copies the user
code to the clipboard before opening the verification URL.

OAuth client-ID setup for the publish-time swap: see
[OAuthAppSetup.md](OAuthAppSetup.md).

Token resolution order, mirroring upstream:

1. `GH_TOKEN` env var
2. `GITHUB_TOKEN` env var
3. Keychain (`com.swiftgh.gh`, account = host)
4. `~/.config/gh/hosts.yml` `oauth_token` field (the upstream
   `--insecure-storage` fallback)
5. nil

Repo inference: `git remote get-url origin` via
`ForgeKit.ProcessGitClient`.

## Subcommand surface

```
gh repo       view / list / create / clone / fork / archive /
              edit / rename / delete
gh pr         list / view / create / edit / merge / close / reopen /
              ready / lock / checkout / checks / comment / diff /
              update-branch
gh issue      list / view / create / edit / close / reopen / lock /
              pin / develop / comment
gh release    list / view / create / download / delete
gh workflow   list / view / run / disable / enable
gh run        list / view (--jobs / --job / --log / --exit-status) /
              watch / rerun / cancel / download
gh project    list / view / create / edit / close / delete /
              copy / template / link / unlink /
              field-list / field-create / field-delete /
              item-list / item-add / item-archive / item-edit /
              item-create / item-delete
gh gist       list / view / create / delete
gh label      list / create / edit / delete / clone
gh search     code / commits / issues / repos / prs
gh org        list (more on the way)
gh ssh-key    list / add / delete
gh gpg-key    list / add / delete
gh variable   list / set / delete (repo + env scopes)
gh secret     list / set / delete (repo + env + dependabot scopes)
gh cache      list / delete
gh config     get / set / list
gh api        the generic raw-API hatch
gh browse     open the resolved repo / PR / issue / file / commit
              in your browser (with `--no-browser` for printing only)
gh version
```

## Networking

- REST against `https://api.github.com` (or `https://<host>/api/v3`
  for GHES).
- GraphQL against `https://api.github.com/graphql`.
- Pagination follows the `Link: rel="next"` header (the GitHub
  convention, contrast with GitLab's `X-Next-Page`).
- Rate-limit headers (`X-RateLimit-Remaining`, `X-RateLimit-Reset`)
  are surfaced to callers; `gh api` shows them when verbose.
- 401 → `APIError.unauthenticated`, 404 → `.notFound`.
- Rate limits → `.rateLimited(resetAt:remaining:retryAfter:url:)`,
  classified like upstream's `isRateLimitError`: any 429 (GitHub uses it
  for both primary and secondary limits), 403 + remaining=0 (primary),
  or 403 + `Retry-After` (secondary). `retryAfter` carries the wait
  GitHub asked for so callers can honour it instead of guessing.

## Embedded tools (no shellout)

Anything `gh` would otherwise spawn is handled in-process by a sibling
SwiftPorts library. Concretely:

| `gh` feature                                        | What upstream needs           | In-process via                                                                                  |
|-----------------------------------------------------|-------------------------------|-------------------------------------------------------------------------------------------------|
| `gh api --jq <filter>`                              | `jq` (embedded as gojq upstream) | [`JqKit`](../Sources/JqKit/)                                                                     |
| `gh api graphql -f query=...`                       | GraphQL `{query, variables, operationName}` envelope | Built into `ApiCommand` (no external tool)                                                      |
| `gh run view --log`                                 | reading entries out of a ZIP  | [`ZipKit`](../Sources/ZipKit/) (`ZipExtractor.printConcatenatedTextEntries`)                     |
| `gh run download`                                   | downloading workflow ZIP artifacts | `URLSession` + `ZipKit` for any in-process unpacking callers want                                |
| `gh release download --extract` for `.zip`           | `unzip`                       | [`ZipKit`](../Sources/ZipKit/)                                                                  |
| `gh release download --extract` for `.tar`           | `tar`                         | [`TarKit`](../Sources/TarKit/) (libarchive backend)                                              |
| `gh release download --extract` for `.tar.gz` / `.tgz` | `tar` + `gzip`             | `TarKit` (libarchive's gzip filter, available on every platform)                                  |
| `gh release download --extract` for `.tar.bz2`        | `tar` + `bzip2`              | `TarKit` (libarchive's bz2 filter, gated to macOS / Linux / Windows by libbz2 availability)      |
| `gh release download --extract` for `.tar.xz` / `.txz` | `tar` + `xz`               | `TarKit` directly on Linux / Windows; on Apple-mobile (no libarchive lzma) chained through [`XzKit`](../Sources/XzKit/) (Compression.framework backend) → `TarKit` |
| `gh release download --extract` for `.tar.zst`        | `tar` + `zstd`               | `TarKit` (libarchive's zstd filter, gated to macOS / Linux / Windows by libzstd availability)    |
| `gh release download --extract` for `.tar.lz4` / `.tlz4` | `tar` + `lz4`             | Always chained: [`Lz4Kit`](../Sources/Lz4Kit/) (Compression.framework on Apple, liblz4 on Linux / Windows) → `TarKit`. Libarchive's lz4 filter isn't compiled in, so this is the only path. |

The reason this matters: an iOS / sandboxed-macOS / server-side Swift
app embedding `GhCommand` can run **all** of the above without
spawning anything external. The same flag set, the same output, the
same exit codes — just no `Process`.

## Local git integration

`gh repo clone`, `gh pr checkout`, `gh pr create`, `gh issue develop`,
and `gh repo fork` go through `ForgeKit.GitClient`. By default
that's `ForgeKit.ProcessGitClient`, which shells out to the user's
`git` binary so their ssh-agent, credential helper, commit-signing
config, and hooks all keep working. Embedders that can't run `Process`
have two alternatives:

- Inject `ForgeKit.NoGitClient` — git-aware commands fail fast with a
  clear "this command needs git" message instead of crashing.
- Inject [`SwiftGit`](../Sources/SwiftGit/)'s `LibGit2GitClient` — a
  libgit2 1.9.x-backed in-process implementation that provides the
  same `GitClient` API. With this wired up, `gh repo clone` /
  `gh pr checkout` / `gh repo fork` run entirely in-process too.

## Adopts

- [`swift-argument-parser`](https://github.com/apple/swift-argument-parser)
- [`swift-http-types`](https://github.com/apple/swift-http-types)
- [`swift-configuration`](https://github.com/apple/swift-configuration)
  (with `YAML` + `CommandLineArguments` traits)
- [`swift-crypto`](https://github.com/apple/swift-crypto)
- [`Yams`](https://github.com/jpsim/Yams) for hosts.yml read/write
- Apple's `Security` framework for Keychain access
- Sibling SwiftPorts ports — see the embedded-tools table above.

## Skipped / out of scope

- **`gh attestation`** — Sigstore + transparency-log stack, large
  dependency footprint.
- **`gh codespace ssh`** — needs dev-tunnels and PTY plumbing.
- **`gh extension install`** — upstream extensions are Go binaries;
  the plugin model doesn't translate cleanly.
- **Web-OAuth flow** — device-code OAuth is sufficient.

## Testing

```bash
swift test --filter GitHubTests
```

`GitHubTests` covers SDK decode round-trips, OAuth device-flow
state machine, networking against a `URLProtocol` mock, hosts.yml
parsing, command argv parsing for the bigger commands, and a tiny
set of opt-in live API tests gated by `GH_TOKEN` env var.

Fixtures: `Tests/GitHubTests/Fixtures/` holds captured GitHub API
JSON responses used by the decode tests.
