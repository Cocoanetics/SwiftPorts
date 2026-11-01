# SwiftGit

In-process git client backed by libgit2 1.9.x via the
[ibrahimcetin/libgit2](https://github.com/ibrahimcetin/libgit2)
SwiftPM package. Drop-in replacement for `Process`-based git
shellouts; works on macOS / iOS / Linux without needing the system
`git` binary on `$PATH`.

## Module layout

The umbrella folder is `Sources/SwiftGit/` so the lowercase `git`
exec target doesn't case-fold-collide with the SDK lib name on
macOS's case-insensitive filesystem.

| Target | Purpose |
|---|---|
| `SwiftGit` | The SDK library — `import SwiftGit`. Provides the canonical `GitClient` concrete type plus the `ForgeKit.GitClient` protocol conformance. |
| `GitCommand` | `AsyncParsableCommand` types for the CLI. SwiftBash extends `GitCommand` to register the whole tree as a Bash builtin. |
| `git` | Executable wrapper, four-line `Entry.swift`. |

## SDK API surface

Everything is on `SwiftGit.GitClient`. Construct with an optional
working directory (default = cwd) and an optional `CredentialProvider`
closure for HTTPS / SSH auth.

```swift
import SwiftGit

let client = GitClient(
    workingDirectory: URL(fileURLWithPath: "/path/to/repo"),
    credentials: CredentialProviders.token(myToken))
```

### Reads

| Method | Maps to |
|---|---|
| `remoteURL(named:)` | `git remote get-url <name>` |
| `remoteList()` | `git remote` |
| `remoteExists(named:)` | helper — `branch.<x>.remote` lookup |
| `currentBranch()` | `git rev-parse --abbrev-ref HEAD` |
| `upstreamBranch(of:)` | `git rev-parse --abbrev-ref <local>@{upstream}` |
| `localBranches()` | `git branch` |
| `tagList(pattern:)` / `tagDetails(pattern:)` | `git tag [-l <pattern>]` / `-n` |
| `resolveOID(_:)` | `git rev-parse <spec>` |
| `gitDir()` / `toplevel()` / `isInsideWorkTree()` | `git rev-parse --git-dir / --show-toplevel / --is-inside-work-tree` |
| `indexedPaths()` | `git ls-files` |
| `status()` → `StatusReport` | `git status` (verbose / `-s` / `--porcelain` / `-sb`) |
| `log(_:)` → `[LogEntry]` | `git log` with start / exclude / pathspec / count |
| `diff(_:format:paths:contextLines:)` | `git diff` (patch / stat / shortstat / numstat / raw / name-only / name-status), supports `<a>..<b>` ranges |
| `mergeBase(_:_:)` | `git merge-base <a> <b>` |
| `canResolveRef(_:)` | safe-probe form of `resolveOID` |
| `blame(path:)` → `[BlameHunk]` | `git blame <path>` |
| `configGet/Set/Unset/List(scope:)` | `git config --local/--global/--system` |
| `commitDetailed(...)` | `git commit` with full diff stats + author/committer split |
| `describe(committish:tags:abbrev:dirty:)` | `git describe [--tags] [--dirty] [--abbrev <n>]` |
| `lsTree(treeish:recursive:)` → `[TreeEntry]` | `git ls-tree [-r] <treeish>` |
| `treeBlobs(of:prefix:)` / `commitTime(of:)` | recursive tree blob walk / commit timestamp backing `git archive` |
| `objectMetadata(of:)` / `catFileBlob(_:)` | `git cat-file -t/-s` and `-p` (blobs) |
| `reflog(refName:)` → `[ReflogEntry]` | `git reflog [<ref>]` |
| `apply(diff:location:)` | `git apply [--cached, --index]` |
| `worktreeList()` → `[GitWorktreeInfo]` | `git worktree list` |

### Writes

| Method | Maps to |
|---|---|
| `initRepository(bare:initialBranch:reinit:)` | `git init [--bare] [-b <branch>]` |
| `clone(url:directory:depth:singleBranch:branch:)` | `git clone [--depth N] [--single-branch] [--branch <name>] <url> [<dir>]` |
| `fetch(remote:refspecs:depth:prune:)` / `unshallow(remote:refspecs:prune:)` | `git fetch [--depth N\|--unshallow] [--[no-]prune] <remote> [<refspec>…]`: one fetch, so a negative `^<ref>` excludes what the others match; no refspecs fetch what the remote is configured to fetch (else its `HEAD`); a relative path, typed or a configured remote's URL, is relative to the top of the work tree, as in git, and `From` and `FETCH_HEAD` show it as typed or configured. `fetch(remote:refspec:…)` takes one |
| `pull(...)` / `pullRebase(...)` | `git pull` / `git pull --rebase` |
| `push(remote:refspecs:setUpstream:)` → pushed refspecs | `git push [-u] <remote> [<refspec>…]`: one push, patterns, `:` (matching branches) and negative `^<ref>` included; no refspecs push `remote.<name>.push`; a relative path, typed or a configured URL or push URL, is relative to the top of the work tree, `To` and `failed to push some refs to '…'` show it as typed or configured, and `-u` records it as typed. Refs git would refuse are left out and reported as GitKit's `PushRejectedError` once the rest went through; `git push` turns it into git's verdict and advice. `push(remote:refspec:setUpstream:)` takes one |
| `quiet = true` (property) | `-q` / `--quiet` for `clone`, `fetch`, `pull` and `push`: no progress lines or per-ref summaries |
| `add(paths:)` | `git add -A` (empty paths) / `git add -- <paths>` |
| `commit(message:author:allowEmpty:)` | `git commit` |
| `merge(ref:fastForward:message:author:)` / `mergeContinue(...)` | `git merge` (--ff / --no-ff / --ff-only) / `git merge --continue` |
| `rebase(upstream:onto:author:)` | `git rebase <upstream> [--onto <onto>]` |
| `rebaseContinue / rebaseSkip / rebaseAbort` | `git rebase --continue / --skip / --abort` |
| `cherryPick(_:author:)` / `cherryPickContinue / cherryPickAbort / cherryPickSkip` | `git cherry-pick` family |
| `checkout(ref:)` | `git checkout <ref>` |
| `checkoutNewBranch(name:startPoint:force:)` | `git checkout -b/-B <name>` |
| `checkoutPaths(_:)` / `checkoutPaths(_:from:)` | `git checkout -- <paths>` / `git checkout <ref> -- <paths>` |
| `reset(to:mode:)` / `reset(paths:from:)` | `git reset --soft/--mixed/--hard` / `git reset HEAD <paths>` |
| `addRemote(name:url:)` / `remoteDelete / remoteRename / remoteSetURL` | `git remote add / remove / rename / set-url` |
| `branchDelete(name:force:)` / `branchRename(...)` | `git branch -d/-D / -m/-M` |
| `tagCreate(name:target:force:)` / `tagCreateAnnotated(...)` / `tagDelete(name:)` | `git tag` family |
| `verifyTag(_:inTagNamespace:)` | `git verify-tag` / `git tag -v` — OpenPGP verification through `gpg.program` / `gpg.openpgp.program`, SSH verification through `gpg.ssh.program` (`ssh-keygen -Y find-principals` / `verify`) against `gpg.ssh.allowedSignersFile` and `gpg.ssh.revocationFile` (launched via the shell's `ProcessLauncher`; x509 is reported unsupported); signed tags in merge / pull messages carry the verification, commented |
| `move(from:to:)` / `remove(paths:keepWorktree:force:)` | `git mv` / `git rm` |
| `stashSave(message:author:flags:)` / `stashApply / stashPop / stashDrop / stashList / stashClear / stashShow / stashBranch` | `git stash` family |
| `worktreeAdd(path:branch:force:)` / `worktreeRemove(name:force:)` | `git worktree add/remove` |

### Auth

`CredentialProvider` is a `@Sendable (URL, String?, CredentialKind) -> Credentials?`
closure invoked by libgit2's transport layer. Returning `nil`
yields `GIT_PASSTHROUGH` (-30) so libgit2 surfaces a clean auth
error rather than treating us as the authority that aborted.

`Credentials` cases:
- `.userPassword(username:password:)` — HTTPS basic auth
- `.token(_:username:)` — sugar for HTTPS token auth, defaults to `x-access-token`
- `.sshKey(username:publicKey:privateKey:passphrase:)` — SSH key files
- `.sshAgent(username:)` — defer to ssh-agent
- `.username(_:)` — only the username (used when SSH transport asks for it)
- `.default` — Negotiate / NTLM via OS facilities

`CredentialProviders.token(_:)` is a ready-made provider for the
common GitHub / GitLab token case.

### Progress

`fetch` / `clone` / `push` install all five callback slots libgit2
exposes:

- `sideband_progress` — server-side `remote: …` lines
- `transfer_progress` — `Receiving objects: …%` (throttled to 1% increments)
- `update_refs` — per-ref `<old>..<new>  <ref>  -> <tracking>` lines, accumulated and flushed as a `From <url>` block after the network op
- `pack_progress` — `Counting/Compressing objects: …` for push
- `push_transfer_progress` — `Writing objects: …%`
- `push_update_reference` — per-ref `[new branch]` / `[rejected]`
  summary, accumulated and flushed as a `To <url>` block

Local-URL detection (`file://`, bare paths) suppresses the
transfer / sideband / pack noise to match real git's local-transport
behaviour. Per-ref summary still emits.

## CLI surface

The `git` binary covers the everyday surface. Output and exit-code
semantics mirror real git for every supported case (verified via
side-by-side `diff` against `/usr/bin/git`).

```
git clone [--depth N] [--single-branch] [--branch <name>] / fetch [--depth N|--unshallow] / pull [--rebase] / push
git checkout {-b/-B/--/<ref> --}
git switch [-c/-C] / restore [--staged] [--source]
git add [-A] [-f] / commit [-m] [--allow-empty] [--author "Name <email>"]
git reset {--soft, --mixed, --hard} [<commit>] [-- <paths>]
git status {-s, --porcelain, -b}
git diff [--cached] [--stat / --shortstat / --numstat / --raw /
          --name-only / --name-status] [-U<n>]
         [<a>..<b> / <a>...<b>] [-- <paths>]
git log [--oneline] [--format <tmpl>] [--stat] [-p] [-<n>]
        [<ref>] [<a>..<b>] [-- <paths>]
git show [<commit-or-tag>]
git rev-parse [--short / --abbrev-ref / --is-inside-work-tree /
               --git-dir / --show-toplevel] <specs>...
git ls-files
git blame <path>
git mv <src> <dst>
git rm [--cached] [-f] <paths>...
git clean [-f] [-n] [-d] [<paths>...]
git config [--global / --system / --local] [--get / --unset /
            --list / -l] <name> [<value>]
git stash {push, list, apply, pop, drop, clear, show, branch}
git tag {-a -m, -d, -l, -n, -f, -v}
git verify-tag {-v, --raw}
git remote {-v, add, get-url, set-url, remove, rename}
git branch {-d, -D, -m, -M, --show-current, --upstream}
git merge {--ff, --no-ff, --ff-only}
git rebase {<upstream>, --continue, --skip, --abort, --onto}
git cherry-pick {<commit>, --continue, --skip, --abort}
git version
```

### Argv preprocessing

`GitCommand.preprocess(_:)` rewrites real-git shorthands before
ArgumentParser sees them. The standalone executable and embedded
ShellKit command registry both call the same hook:

- `-U<n>` → `-U <n>` (diff context lines)
- `-<n>` → `-n <n>` (log count limit, `git log` only)
- bare `--color` → `--color=always` (`git diff` / `git status`)

ArgumentParser's `customShort` doesn't natively support attached
short-option-with-value forms for typed options.

## Side-by-side parity testing

Most commands have a `byte-identical-to-real-git` test. The pattern:

```swift
let ours = try await SwiftGit.GitClient(workingDirectory: dir)
    .status().shortFormat(branchHeader: true)
let theirs = try runGit(["status", "-sb"], in: dir)
#expect(ours == theirs)
```

For commands with variable output (SHAs, dates) we sed-strip those
parts before diffing. Where libgit2's behaviour diverges from real
git by design (e.g. local-clone progress), we suppress the diff and
document the gap instead of fighting it.

## SwiftBash registration

`GitCommand` is the parsable root — registering it makes the entire
subcommand tree (`git status`, `git stash list`, `git rebase
--abort`, …) addressable as a single Bash builtin:

```swift
import GitCommand
import BashInterpreter
import ArgumentParser

extension GitCommand: ParsableBashCommand {
    public mutating func execute() async throws -> ExitStatus {
        do { try await self.run(); return .success }
        catch let code as ExitCode { return ExitStatus(rawValue: Int(code.rawValue)) }
    }
}
```

## Caveats

- HTTPS auth uses libgit2's built-in HTTP parser + SecureTransport on Apple platforms; OpenSSL-dynamic on Linux. Neither path honours `~/.gitconfig`'s `credential.helper` — token-bearing pushes need the token in the URL or via the `CredentialProvider` callback.
- SSH auth uses `GIT_SSH_EXEC` (system `ssh` binary). Won't work on iOS / sandboxed embedders.
- `git rebase -i` (interactive todo file) — libgit2 has no driver. Skipped.
- `git log --graph` — ASCII rendering is fiddly, libgit2 has no helper. Skipped.
- `git diff --color` / `--word-diff` — libgit2 has no colorizer / word-tokenizer. Skipped.
- `--ahead-behind` annotations on status / branch listing — would need `git_graph_ahead_behind` per ref. Possible follow-up.
- `git rebase --interactive`, `git submodule`, `git worktree lock/move/prune/repair/unlock`, `git bisect`, `git filter-branch` — out of scope.

## Sandbox and the host's system gitconfig

In a rooted sandbox, libgit2's SYSTEM config level is disabled by default
(`SET_SEARCH_PATH(SYSTEM, "")`): the host's `/etc/gitconfig` can set credential
helpers and include paths outside the sandbox. This covers every command in a
repository and unscoped `git config` reads outside one; an explicit
`git config --system` on the host's file is refused by `Shell.authorize`.

An embedder opts in by binding `GitSandboxPolicy.allowsHostSystemConfig` around
the commands that should read it:

```swift
await GitSandboxPolicy.$allowsHostSystemConfig.withValue(true) { … }
```

`GIT_CONFIG_NOSYSTEM=1` still leaves the system level out. Without a sandbox
nothing changes. There is no `git` CLI flag for this.

## The environment's config

The shell's `HOME`, `XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL`,
`GIT_CONFIG_SYSTEM`, `GIT_CONFIG_NOSYSTEM` and `GIT_CONFIG_COUNT` /
`GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` change what every command reads
(commit identity included), sandbox or not, not only `git config --global`:

- `HOME` / `XDG_CONFIG_HOME` (the shell's, else the process's without a
  sandbox) point libgit2's global and XDG search at them.
- `GIT_CONFIG_GLOBAL` replaces `~/.gitconfig` *and* the XDG file; a relative
  name is the shell's working directory's, and `--show-origin` prints it as
  typed. `/dev/null` or an empty value leaves both out.
- `GIT_CONFIG_SYSTEM` names the system file, unless `GIT_CONFIG_NOSYSTEM` is
  true. A sandbox reads it only inside its root (or with
  `allowsHostSystemConfig`); a file a sandbox may not read is left out, as the
  host's own is. A `GIT_CONFIG_GLOBAL` file outside the root is a denial
  (`/dev/null` excepted). Each `[include]` / `[includeIf]` path libgit2 opens
  is authorised through the sandbox (GitKit 2.9.0); a path outside the root
  is a denial.
- `GIT_CONFIG_COUNT` entries are the highest level, shown by `--show-origin`
  as `command line:`. What git can't parse stops the command with git's
  `fatal: unable to parse command-line config`.

libgit2 reads none of these itself, so `Libgit2Sandboxing` switches off the
levels they replace and `GitClient.installEnvironmentConfig` adds the file or
entries to the open config. GitKit's `Repository` keeps its handle internal;
`withRepository` reaches it by reflection (a test fails if GitKit stops having
it). `clone` and `init` open their repository inside GitKit, so they see
`HOME` / `XDG_CONFIG_HOME` but not the `GIT_CONFIG_*` overrides yet.

`git config --show-origin` (with `--list` or a single key) prints
`file:<path>` / `command line:` and a tab before each entry.
