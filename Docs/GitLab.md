# GitLab port (`glab`)

Pure-Swift port of [`gitlab-org/cli`](https://gitlab.com/gitlab-org/cli)
(`glab`). Targets the `glab issue` surface first; everything else is
TODO.

## Targets

| Target / Product | Role |
|------------------|------|
| `GitLab` (lib)        | API client (`X-Next-Page` pagination, Bearer auth), Codable models, `RepositoryReference` (with nested-subgroup support), `Configuration` + `ConfigurationResolver`. No ArgumentParser dependency. |
| `GlabCommand` (lib)   | The full subcommand tree as `AsyncParsableCommand` types. Importable across packages — SwiftBash extends `GlabCommand` to register the whole tree as a Bash builtin. |
| `glab` (exec)         | Four-line `Entry.swift` wrapper. `@main` delegates to `GlabCommand.main()`. |

Layout under `Sources/GitLab/{Lib,GlabCommand,glab}/` per the
SwiftPorts umbrella convention (see [AGENTS.md](../AGENTS.md)).

## What works

### Issue surface (parity with `glab issue --help` from upstream)

```
glab issue list           --repo, --assignee, --author, --label, --milestone,
                          --search, --all, --closed, --confidential,
                          --per-page, --page, --json
glab issue view <id|url>  --repo, --web, --comments, --json
glab issue create         --title (req), --description, --label, --assignee,
                          --milestone, --confidential, --json
glab issue update <id>    --title, --description, --label/--unlabel,
                          --assignee/--unassign, --milestone, --confidential/--public,
                          --lock-discussion/--unlock-discussion, --weight,
                          --due-date, --json
glab issue close <id>
glab issue reopen <id>
glab issue note <id>      --message (req)
glab issue subscribe <id>
glab issue unsubscribe <id>
glab issue delete <id>
glab issue board list                  list project boards
glab issue board view [<id>]           pretty-print metadata; no <id>
                                       opens the boards page in browser
glab issue board create [<name>]       --name / -n <name>
glab issue board delete <id>           --yes / -y skips the confirm prompt
                                       (otherwise re-types the board name)
```

`<id>` for any of the above is one of: `123`, `#123`, or a full URL
like `https://gitlab.com/group/sub/repo/-/issues/123`. URL form
overrides `--repo` and switches the API client to the URL's host
automatically — same behaviour as upstream `glab`.

### Merge-request surface

```
glab mr list                 --repo, --assignee, --author, --reviewer,
                             --label, --milestone, --source-branch,
                             --target-branch, --search, --all/--closed/
                             --merged/--draft, --per-page, --page, --json
glab mr view <id|!iid|url>   --repo, --web, --comments, --json
glab mr create               --repo, --title (req), --description,
                             --source-branch (default: cwd branch),
                             --target-branch (default: project default),
                             --label, --assignee, --reviewer, --milestone,
                             --draft, --squash, --remove-source-branch, --json
glab mr update <id>          --repo, --title, --description, --label/--unlabel,
                             --assignee/--unassign, --reviewer, --milestone,
                             --target-branch, --draft/--ready, --json
                             (--draft + --title compose: "Draft: <title>")
glab mr close <id>
glab mr reopen <id>
glab mr merge <id>           --squash, --remove-source-branch,
                             --merge-commit-message, --squash-commit-message,
                             --when-pipeline-succeeds, --json
                             (alias: glab mr accept)
glab mr approve <id>         (shows approval count after)
glab mr unapprove <id>       (alias: glab mr revoke)
glab mr note <id> -m "..."   (alias: glab mr comment)
glab mr subscribe / unsubscribe <id>
glab mr checkout <id>        --branch <local-name>, --remote (default: origin)
                             fetches refs/merge-requests/<iid>/head and
                             checks out via GitClient.fetch + checkout
glab mr diff <id>            --web, --json
                             colorised unified-diff print by default
glab mr delete <id>
```

`<id>` accepts `123`, `!123`, `#123`, or a full URL like
`https://gitlab.com/group/sub/repo/-/merge_requests/123`. URL form
overrides `--repo` and switches the API client to the URL's host.

### Repo (project) surface

```
glab repo view [<repo>]      --repo, --web, --json
glab repo list               --hostname, --group <full-path>, --user,
                             --owned, --starred, --membership,
                             --visibility, --search, --per-page, --page, --json
glab repo create <name>      --hostname, --group, --description,
                             --visibility (default: private),
                             --default-branch, --[no-]issues / --[no-]merge-requests
                             / --[no-]wiki, --initialize-with-readme, --json
glab repo clone <repo> [dir] --https
                             SSH by default; falls back via `--https`
glab repo fork <repo>        --namespace, --name, --path, --json
glab repo archive [<repo>]
glab repo unarchive [<repo>]
glab repo edit [<repo>]      --description, --default-branch, --visibility,
                             --enable-issues / --disable-issues,
                             --enable-mrs / --disable-mrs,
                             --enable-wiki / --disable-wiki,
                             --enable-snippets / --disable-snippets
                             (toggles route through *_access_level fields)
glab repo delete [<repo>]    -y/--yes to skip the confirmation prompt
                             (otherwise re-types the path to confirm)
```

`repo clone` and `mr checkout` route through `SwiftGit.GitClient`
(libgit2 in-process) — no system `git` binary required.

### CI/CD surface

```
glab ci list                  --repo, --status, --ref, --source, --per-page,
                              --page, --json
glab ci view [<id>]           --repo, --branch, --web, --json
                              (no <id> → latest pipeline on resolved branch)
glab ci trace <id|name>       --repo, --branch, --poll-interval, --no-follow
                              streams a job log via Range: bytes=N-
glab ci status                --repo, --branch, --poll-interval, --once
                              live one-line status; refresh until terminal
glab ci retry [<id>]          --repo, --branch
glab ci cancel [<id>]         --repo, --branch
glab ci run                   --repo, --branch, -v KEY=VALUE (repeatable)
glab ci lint [path|-]         POST /projects/:id/ci/lint of the file content
                              (defaults to .gitlab-ci.yml; `-` reads stdin)
```

`<id>` defaults to "latest pipeline for the resolved branch" everywhere.
The branch resolves: `--branch` flag > cwd's `currentBranch` from
`ProcessGitClient`. `glab ci trace` accepts either a numeric job ID or
a job name (matched against the latest pipeline's jobs).

`ci status` and `ci trace` exit with code 1 when the underlying
pipeline / job ends in `failed`, mirroring `gh run watch
--exit-status`.

### Release / tag / variable / label / api surface

```
glab release list             --repo, -l/--limit
glab release view <tag>       --repo
glab release create <tag>     --repo, -n/--name, -r/--ref, --no-update,
                              -N/--notes "...", -F/--notes-file <path|->
                              creates the release, or updates an
                              existing one's name / notes (one PUT)
glab release delete <tag>     --repo
glab release download <tag>   --repo, -p/--pattern (repeatable, glob),
                              -D/--dir <dir>, --sources
                              downloads link assets (and optionally
                              the auto-generated source archives)

glab tag list                 --repo, -s/--search, -l/--limit
glab tag create <tag> [<ref>] --repo, -m/--message (annotated tag)
glab tag delete <tag>         --repo

glab variable list            --repo, --show-values
glab variable set <key> <v>   --repo, -p/--protected, -m/--masked,
                              --raw, -t/--type (env_var|file),
                              --scope <env>
                              (`-` for value reads from stdin;
                              tries PUT first, falls back to POST)
glab variable unset <key>     --repo

glab label list               --repo, -l/--limit, --json
glab label create <name>      --repo, -c/--color (hex), -d/--description
glab label delete <name>      --repo, -y/--yes

glab api <endpoint>           -X/--method, -F/--field KEY=VAL (typed),
                              -f/--raw-field KEY=VAL (string),
                              -i/--include, --hostname
```

### Auth surface

```
glab auth status   [-h <host>] [--show-token]
glab auth login    [-h <host>] [--with-token]   PAT-based
glab auth logout   [-h <host>]
glab auth token    [-h <host>]                  Print resolved token
```

Token resolution order, mirroring upstream:

1. `GITLAB_TOKEN` env var
2. `GITLAB_ACCESS_TOKEN` env var
3. `OAUTH_TOKEN` env var
4. Keychain (`com.swiftgl.glab`, account = host)
5. nil

Host resolution: explicit `-h` flag > `GITLAB_HOST` > `GITLAB_URI` >
`GL_HOST` > `gitlab.com`.

`auth login` is **PAT-only**. Create a token at
<https://gitlab.com/-/user_settings/personal_access_tokens> (or the
equivalent on a self-hosted instance) and paste it. Pipe a token
non-interactively with `--with-token`. The OAuth device-flow / web
callback login from upstream `glab` is not implemented here.

### Repository reference

Parses any of:

- `OWNER/REPO`
- `GROUP/SUB/REPO` (and arbitrarily deeper subgroup chains)
- `HOST/OWNER/REPO`, `HOST/GROUP/.../REPO` — first segment becomes
  the host iff it contains a `.`
- a full HTTPS / SSH git remote URL

`encodedPath` percent-encodes only the `/` separators
(`gitlab-org%2Fcli`, `group%2Fsub%2Frepo`) — the form GitLab's REST
API expects.

### Host resolution

When `-R` carries no host (`-R group/repo`), the resolver:

1. Checks the cwd's `origin` git remote — if it parses to a GitLab
   URL, the **host** from that remote is grafted onto the `-R` path.
   Lets `glab issue list -R group/repo` "just work" inside a clone of
   any self-hosted instance with no `--hostname` / `GITLAB_HOST`.
2. Falls back to `GITLAB_HOST` / `GITLAB_URI` / `GL_HOST` if the cwd
   has no usable remote.
3. Falls back to `gitlab.com` if nothing else applies.

Explicit hosts (`-R host.example.com/group/repo`, full URL form)
always win — no inference happens when a host is already present.
With no `-R` at all, both the host and path are inferred from the
cwd remote.

## What doesn't work yet

- **OAuth device flow** for `auth login` (PAT-only today).
- **Editor-driven description / body editing** — upstream `glab` lets
  you pass `-d -` or omit `-t` to drop into `$EDITOR`. Not ported;
  pass the body inline via `-d "..."`.
- **`glab mr rebase`** — niche; the rest of the MR surface is in.
- **Kanban board TUI** — board *management* (list / view / create /
  delete) is wired via the API. The terminal kanban TUI from upstream
  is not ported; `glab issue board view` with no ID opens the boards
  page in a browser, which gives you GitLab's full drag-and-drop UI.
- **`glab ci config / artifact / delete / get / trigger`** — the rest
  of the CI surface beyond list / view / trace / status / retry /
  cancel / run / lint.
- **`glab schedule`** — pipeline schedules.
- **`glab runner`** — runner administration.
- **`glab snippet ...`**, `glab cluster ...`, `glab incident ...`,
  `glab token ...` — upstream surfaces we don't carry. (`release`,
  `tag`, `variable`, `label`, `api` are now in.)

## Testing

```bash
swift test --filter GitLabTests
```

`GitLabTests` covers `RepositoryReference` parsing across the formats
listed above, `Configuration` env-var precedence, `IssueArgument`
parsing (numeric, `#123`, URL), `Issue` JSON decoding from a captured
fixture, and argv parsing for every issue + auth subcommand.

## Live verification

`glab issue list --repo gitlab-org/cli --per-page 5` and `glab issue
view --repo gitlab-org/cli 1` work end-to-end against gitlab.com
without auth (read-only public endpoints). With a PAT in
`GITLAB_TOKEN`, write-side commands (`create`, `update`, `close`,
`reopen`, `note`, `subscribe`, `unsubscribe`, `delete`) work against
projects you have access to.
