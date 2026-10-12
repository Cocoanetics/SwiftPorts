# SSH

In-process, OpenSSH-compatible SSH client on mainline
[apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh). Issue
[#111](https://github.com/Cocoanetics/SwiftPorts/issues/111)'s Phase 1:
`SSHKit` (library only). Phase 2
([#113](https://github.com/Cocoanetics/SwiftPorts/issues/113)): `GitKitSSH`,
an in-process SSH transport for GitKit built on `SSHKit` — see
[GitKitSSH](#gitkitssh-issue-113) below. `SSHCommand`/`ssh` lands in a
follow-up issue (#114).

## Module layout

```
Sources/SSHKit/Lib/
  SSHError.swift                       OpenSSH-worded errors (host key / auth / config)
  SSHPatternList.swift                 shared Host/known_hosts glob matcher
  SSHPath.swift                        tilde expansion via Shell.homeDirectory
  SSHPublicKeyDescribing.swift         algorithm id / sshkey_type() short name / SHA256 fingerprint
  Config/
    SSHConfig.swift                    ssh_config(5) parser + resolve(host:)
    SSHHostConfig.swift                resolved per-host settings
    SSHStrictHostKeyChecking.swift     yes / no / ask / accept-new
  KnownHosts/
    KnownHostsStore.swift              parse / load / match / record
    KnownHostsEntry.swift              one parsed line (plain or hashed)
    HostKeyHashing.swift               |1| HMAC-SHA1 hashed host field
  Identity/
    IdentityLoader.swift               loads an OPENSSH PRIVATE KEY file
    OpenSSHPrivateKeyFile.swift        openssh-key-v1 container parser
    SSHWireReader.swift                SSH binary wire format (uint32/string/mpint)
  Client/
    SSHClient.swift                    connect + exec
    SSHHostKeyVerifier.swift           NIOSSHClientServerAuthenticationDelegate
    SSHPublicKeyAuthenticationDelegate.swift   NIOSSHClientUserAuthenticationDelegate
    SSHExecChannel.swift               async stdin/stdout/stderr + exit status

Tests/SSHKitTests/
  Fixtures/                 real ssh-keygen-generated keys, known_hosts, ssh_config
  Support/                  InProcessSSHServer (portable), ThrowawaySSHD (macOS/Linux)
```

`SSHKit` (target name matches the umbrella folder, per AGENTS.md's naming
convention) and `GitKitSSH` (see [below](#gitkitssh-issue-113)) ship
today — no `SSHCommand`/`ssh` executable yet.

## SDK API surface

```swift
import SSHKit

let config = try await SSHConfig.load(path: "~/.ssh/config")
let hostConfig = try config.resolve(host: "example.com")

let identities = try await IdentityLoader.loadAvailable(paths: hostConfig.identityFiles)
let knownHosts = try await KnownHostsStore.load(paths: hostConfig.userKnownHostsFile)

let client = try await SSHClient.connect(
    host: hostConfig.hostName,
    port: hostConfig.port,
    username: hostConfig.user ?? currentUsername,
    identities: identities,
    knownHosts: knownHosts,
    userKnownHostsFilePath: hostConfig.userKnownHostsFile.first,
    strictHostKeyChecking: hostConfig.strictHostKeyChecking
)

let exec = try await client.exec("git-upload-pack '/repo.git'")
for await chunk in exec.stdout { ... }
let status = try await exec.exitStatus
try await client.close()
```

`SSHClient.connect` returns once the TCP connection is up **and**
host-key verification has resolved — a bad host key fails here,
immediately, the way real `ssh` aborts before user auth even starts.
Public-key authentication completes lazily: an exhausted-identities
failure surfaces the first time `exec(_:)` is called, as
`SSHError.permissionDenied`.

Connect cancellation closes the underlying channel, and channel teardown
settles both the host-key-completion and authentication-exhaustion
promises on every path. Dropping a connected `SSHClient` without an
explicit `close()` also initiates that teardown. This prevents NIO's
debug promise-leak trap when a connection attempt is abandoned midway.

### Scope (issue #112)

- `ssh_config(5)`: `Host`, `HostName`, `Port`, `User`, `IdentityFile`,
  `IdentitiesOnly`, `UserKnownHostsFile`, `StrictHostKeyChecking`. Every
  other real keyword is recognized (so real config files still parse)
  but has no effect; a genuinely unknown keyword is a bad-configuration
  error, matching `readconf.c`. `Match` blocks are recognized but never
  apply — this port doesn't evaluate `Match` conditionals.
- `known_hosts`: plain and hashed (`|1|`) entries, `*`/`?` glob +
  comma-list + `!`-negation host patterns. No `@cert-authority`/`@revoked`
  markers, no `CheckHostIP`, no `VerifyHostKeyDNS`.
- Keys: unencrypted ed25519 and ECDSA (P-256/384/521) `openssh-key-v1`
  files only. No RSA, no ssh-agent, no encrypted keys — see Phase 0
  findings below for why.
- Auth: public key only (no password / keyboard-interactive / host-based).
- Channels: exec only (stdin/stdout/stderr + exit status). No PTY, no
  port forwarding.
- No TTY/prompt plumbing. `StrictHostKeyChecking ask`'s interactive
  confirmation is `SSHCommand`'s concern (#114); until then, `ask`
  behaves exactly like real `ssh` under `BatchMode=yes` or a non-tty
  stdin — it fails closed without printing a prompt, because
  `confirm()` itself returns "no" silently in that case
  (`sshconnect.c` line 610-611).

## GitKitSSH (issue #113)

Flat library, `Sources/GitKitSSH/`, implementing GitKit 2.2.0's
`GitSSHTransportProvider`/`GitSSHChannel` hook
([`Sources/GitKit/SSHTransport.swift`](https://github.com/Cocoanetics/GitKit/blob/main/Sources/GitKit/SSHTransport.swift))
over `SSHKit`'s exec channel, so GitKit's `ssh://`/scp-style fetches and
pushes run in-process instead of shelling out to `/usr/bin/ssh` via
libgit2's `ssh_exec`.

```
Sources/GitKitSSH/
  GitKitSSH.swift                     install() / uninstall() — opt-in registration
  GitKitSSHTransportProvider.swift    GitSSHTransportProvider over SSHKit
  GitKitSSHChannel.swift              GitSSHChannel bridging SSHExecChannel's async streams
  GitKitSSHBridge.swift                TaskExecutor + semaphore blocking bridge
  GitKitSSHStderrCollector.swift       drains one channel's stderr concurrently with stdout
  GitKitSSHRemoteCommandError.swift    carries a failed remote command's stderr/exit status

Tests/GitKitSSHTests/
  GitKitSSHEndToEndTests.swift         clone / fetch / push + auth / host-key / missing-repo failures
  GitKitSSHTransportProviderQuotingTests.swift   shellQuote unit tests (quote/bang/space/injection)
  Support/ThrowawaySSHD.swift          duplicated from Tests/SSHKitTests/Support (macOS/Linux)
```

### Host/port/user resolution

`GitKitSSHTransportProvider.openChannel(host:port:user:command:)` receives
whatever the git URL itself specified (`ssh://[user@]host[:port]/path` or
scp-style `user@host:path` — parsed by GitKit, not this port). It layers
`ssh_config(5)` under that the same way `ssh(1)` does: `SSHConfig.resolve(host:)`
supplies `HostName`/`Port`/`User`/`IdentityFile`/`UserKnownHostsFile`/
`StrictHostKeyChecking` for the host, and the URL's own `port`/`user` (when
present) win over the config's. The remote command sent over the exec
channel is `<command> '<path>'` — `git-upload-pack '/repo.git'`,
`git-receive-pack '/repo.git'`, or `git-upload-archive '/repo.git'` —
exactly as `GitSSHTransportProvider.openChannel`'s doc comment specifies.
`path` is shell-quoted by `GitKitSSHTransportProvider.shellQuote(_:)`,
matching git's own `sq_quote_buf` (`quote.c`): wrap in single quotes, turn
each embedded `'` into `'\''` and each `!` into `'\!'` (the latter defends
a remote login shell that is csh/tcsh, where `!` triggers history
expansion even inside single quotes) — a path straight from a parsed
remote URL is otherwise attacker-controlled input reaching a remote shell
command line.

### Threading bridge

GitKit's `GitSSHChannel` contract is synchronous and is called directly by
libgit2's C callbacks, on whichever thread is driving the git operation
(`Repository.fetch`/`clone`/`push` are themselves synchronous, throwing
calls — not `async`). `GitSSHChannel.read`/`write`/`close` must block that
thread until they can make progress; they must never `await` a Swift
concurrency task directly, since that would hop off the calling thread,
which libgit2 does not expect.

`GitKitSSHBridge.runBlocking(_:)` is the bridge: on runtimes that support
SE-0417 (`Task(executorPreference:)`), it starts a task with a preference
for `GitKitSSHBridgeExecutor`'s dedicated, non-cooperative-pool OS thread,
then blocks the *calling* thread on a `DispatchSemaphore` until that task's
async work — an `SSHExecChannel` read/write, or `SSHClient.connect`/`exec`
during `openChannel` — finishes. The task-executor preference matters
beyond initial scheduling: it follows the task through SSHKit's
nonisolated async APIs, which otherwise move to the global cooperative
executor under SE-0338.

Earlier builds started a plain unstructured `Task` here instead, which
Swift schedules onto its cooperative thread pool. `SwiftGit`'s
`GitClient` drives libgit2 from `async` code
(`Libgit2Sandboxing.runIsolated`), so the thread calling into
`runBlocking` can itself already be a cooperative-pool thread — blocking
it on a semaphore while the spawned `Task` waited for a pool thread of
its own to free up deadlocked outright once the pool was exhausted (a
single-core CI/agent sandbox, or several concurrent `GitKitSSH`
operations in one process, per issue #113's stated MissionControl
adoption plan).

The close path uses NIO futures synchronously, never on an EventLoop
thread. Event-loop-group shutdown delivers its callback on a private
`SSHClient` dispatch queue rather than the global queue, so teardown also
completes while every cooperative-pool worker is occupied. The
`cloneCompletesUnderSaturatedCooperativePool` end-to-end test saturates
that real pool while a separate OS thread performs a full SSH clone,
including disconnect and event-loop shutdown.

`TaskExecutor` is unavailable before macOS 15 / iOS 18 / tvOS 18 /
watchOS 11. On those older Apple runtimes, `runBlocking` falls back to
the dedicated-thread global actor used by the original implementation.
That keeps actor-isolated bridge scheduling off the pool, but SE-0338
nonisolated SSHKit calls can still require a cooperative-pool worker;
the full pool-starvation guarantee therefore applies only where SE-0417
is available (and on non-Apple runtimes where the API is unconditionally
available).

`GitKitSSHChannel` buffers leftover bytes between `read(into:)` calls
(`SSHExecChannel.stdout` delivers arbitrarily-sized chunks that rarely
line up with libgit2's requested buffer size) and is `@unchecked
Sendable`: libgit2 guarantees serialized, single-threaded access to one
channel for its whole lifetime (ls-refs probe through the final
upload-pack/receive-pack exchange, per GitKit's
`SSHSubtransportContext`), so the unsynchronized mutable iterator/buffer
state is safe in practice despite not being statically checked.

### Registration is opt-in

`GitKitSSH.install(sshConfigPath:)` / `GitKitSSH.uninstall()` wrap
GitKit's `GitSSHTransport.register(_:)`/`unregister()` directly — same
one-at-a-time, process-global synchronization contract. Neither
`SwiftGit` nor `GitCommand` calls `install()`: only SwiftPorts' `git`
executable (`Sources/SwiftGit/git/Entry.swift`) does, at startup, before
any command runs. A host that doesn't link `GitKitSSH` (or that never
calls `install()`) keeps libgit2's `ssh_exec` fallback unchanged — which
is also why `GitKitSSH` had to stay out of `SwiftGit`'s own target
dependencies.

Within the `git` executable itself, calling `install()` is further gated
behind an env var, **default off**:
`SWIFTPORTS_GIT_INPROCESS_SSH=1`. `GitKitSSH` only loads unencrypted
ed25519/ECDSA identities (no ssh-agent, no RSA, no encrypted keys — see
the Phase 0 findings below) and has no interactive prompt for
`StrictHostKeyChecking ask`'s first-connect confirmation (no TTY
plumbing — see the Scope section above). Registering it unconditionally
would silently break interactive clones/fetches/pushes that rely on any
of those (an exhausted-identities failure instead of a working
ssh-agent/RSA key, or a hard failure instead of OpenSSH's "are you sure
you want to continue connecting" prompt for a brand-new host). So
interactive use of this `git` executable keeps libgit2's `ssh_exec`
fallback — and everything that comes with shelling out to the system
`ssh(1)` — until Phase 3 (#115) adds agent/RSA/encrypted-key support and
an interactive prompt to `GitKitSSH` itself. A non-interactive host that
already fully controls its own `known_hosts` and identities
(MissionControl, CI) sets the env var, or — equivalently, and the only
option for a host that embeds `GitKitSSH` as a library rather than
spawning this `git` executable — calls `GitKitSSH.install()` itself.

### Error wording

`openChannel`/`read`/`write` propagate `SSHError` values unwrapped.
GitKit's subtransport bridge catches them and calls `String(describing:
error)`, which resolves to `SSHError.description` for every case here —
so a host-key mismatch or an exhausted-identities failure surfaces to a
GitKit caller as a `Libgit2Error` whose message is OpenSSH's own wording
("Host key verification failed.", "`user@host`: Permission denied
(publickey)."), not a GitKitSSH-specific message.
`GitKitSSHEndToEndTests` asserts both verbatim against a real throwaway
`sshd`.

`GitKitSSHChannel` also surfaces failures from the remote command itself
(`git-upload-pack`/`git-receive-pack` exiting non-zero — e.g. the
repository path doesn't exist on the remote), not just transport-level
failures. `GitKitSSHStderrCollector` drains the exec channel's stderr
into a buffer concurrently with `read(into:)` consuming stdout (a
background `Task` over `SSHExecChannel.stderr`, guarded by a lock since
it runs alongside the synchronous `read`/`write` calls). When `stdout`
hits true EOF, `GitKitSSHChannel` checks `SSHExecChannel.exitStatus`
(already resolved by then — the exit-status event always arrives before
`SSHExecChannelHandler.channelInactive` finishes both streams); a
non-zero status throws `GitKitSSHRemoteCommandError`, carrying whatever
stderr text was collected (or just the exit status, if the remote wrote
none). Without this, libgit2 would only ever see a generic EOF/protocol
failure instead of the remote's own diagnostic.

## Phase 0 findings (verified against source at the pinned commits)

`apple/swift-nio-ssh` at `149f32f` (2026-10-07, tag `0.15.0`,
2026-07-28) and `openssh-portable` at `73c1399` (2026-10-11).

1. **Key types.** `NIOSSHPrivateKey`'s backing store is an internal,
   closed enum: `ed25519`, `ecdsaP256`, `ecdsaP384`, `ecdsaP521`, and
   (Darwin-only) `secureEnclaveP256`
   (`Sources/NIOSSH/Keys And Signatures/NIOSSHPrivateKey.swift`).
   **No RSA, and no pluggable/external signer** — signing happens
   internally against concrete `Crypto` key types. This rules out RSA
   and ssh-agent/Secure-Enclave delegation for Phase 1, matching the
   operator's decision.
2. **Cipher suite.** `Constants.bundledTransportProtectionSchemes` is
   `[AES256GCMOpenSSHTransportProtection, AES128GCMOpenSSHTransportProtection]`
   (`Sources/NIOSSH/Constants.swift`) — `aes256-gcm@openssh.com` /
   `aes128-gcm@openssh.com`, matching the issue's Phase 0 note.
3. **Client API shape.** `SSHClientConfiguration(userAuthDelegate:
   serverAuthDelegate:)`, `NIOSSHHandler(role: .client(...), allocator:,
   inboundChildChannelInitializer:)`, and
   `sshHandler.createChannel(_:channelType:_:)` for an exec channel —
   confirmed against `Sources/NIOSSHClient/main.swift` and
   `ExecHandler.swift`. Channel I/O is `SSHChannelData` (`.channel` /
   `.stdErr` cases); the exit status arrives as a
   `SSHChannelRequestEvent.ExitStatus` user-inbound event. `SSHKit`
   wraps this in its own `ChannelInboundHandler`
   (`SSHExecChannelHandler`) that yields to `AsyncStream`s instead of
   real file descriptors, since the demo code writes straight to stdout.
4. **`NIOSSHPublicKey(openSSHPublicKey:)`** parses the standard
   `"algorithm-id base64-key"` line used by both `known_hosts`' third
   field and `ssh-keygen`'s `.pub` output
   (`Sources/NIOSSH/Keys And Signatures/NIOSSHPublicKey.swift`) — reused
   directly for `KnownHostsEntry` parsing instead of re-implementing the
   public-key wire format.
5. **Auth exhaustion is a no-op in `swift-nio-ssh` 0.15.0.** When a
   `NIOSSHClientUserAuthenticationDelegate` reports it has no further
   offer (succeeds `nextChallengePromise` with `nil`), nothing closes or
   fails the connection:
   `NIOSSHHandler.processInboundMessageResult`'s `.possibleFutureMessage`
   case is a literal `case .success(.none): // Do nothing` (no caller of
   `UserAuthenticationStateMachine.noFurtherMethods()` exists in the
   package at all — it's unreachable dead code). Left alone, this hangs
   the connection forever instead of failing like
   `sshconnect2.c`'s `fatal("... Permission denied ...")`.
   `SSHPublicKeyAuthenticationDelegate.exhaustedPromise` and
   `SSHClient.exec(_:)`'s use of it are this port's workaround: close the
   connection and fail the pending channel-open promise ourselves the
   moment exhaustion is detected, rather than depend on upstream to do
   it. Worth reporting upstream separately from this port.
6. **Private-key container.** `openssh-key-v1`'s layout
   (`PROTOCOL.key` in `openssh-portable`) and the per-key-type private
   blob layout (`ssh_ed25519_serialize_private()` in `ssh-ed25519.c`
   lines 67-78: `string pub(32) + string sk(64, seed‖pub)`;
   `ssh_ecdsa_serialize_private()` in `ssh-ecdsa.c` lines 145-159:
   `string curve-name + string Q + mpint d`) are read with a small,
   local `SSHWireReader` — `NIOSSH`'s own wire-format helpers
   (`readSSHString`/`writeSSHHostKey`) are `internal` to that module and
   not visible here.
7. **`swift-nio-ssh` 0.15.0 cannot run its protocol handshake on
   Windows at all.** `CSPRNG` (`Sources/NIOSSH/CSPRNG.swift`), which
   NIOSSH uses internally for protocol-level randomness (KEX ephemeral
   keys, packet padding), is gated
   `#if canImport(Darwin) || os(Linux) || os(Android)` and
   `fatalError("Platform does not have a supported CSPRNG")` on every
   other platform — confirmed by `build-windows` CI crashing with that
   exact message the instant a real connection attempted KEX. This is
   independent of this port's own code: `SSHKit` compiles cleanly on
   Windows, but any `SSHClient.connect(...)` there will trap. Apple
   platforms (via `canImport(Darwin)`, covering iOS/tvOS/watchOS too)
   and Android are both fine. Tracked as a pure upstream gap — worth
   reporting to `apple/swift-nio-ssh` separately from this port; nothing
   in `SSHKit` can work around a `fatalError` inside a dependency.

## OpenSSH message/exit-code fidelity (quoted, with citations)

Every message `SSHError` carries, and the fact that each of these is
always exit 255 (OpenSSH's `fatal()`), is quoted from
`openssh-portable` at `73c1399`:

- **Host key verification failed** — the single, constant final line
  for every host-key failure (new host under strict checking, a
  changed key, or a declined/impossible interactive confirmation):
  `fatal("Host key verification failed.")`, `sshconnect2.c` line 104.
- **New host, `StrictHostKeyChecking yes`** —
  `error("No %s host key is known for %.200s and you have requested
  strict checking.", type, host)`, `sshconnect.c` lines 1204-1206.
- **New host, `ask`, non-interactive** — no extra line at all:
  `confirm()` checks `options.batch_mode` *before* printing anything
  and returns 0 (`sshconnect.c` lines 610-611), so the only output is
  the constant final line above. `SSHKit` has no TTY, so this is the
  only path it can take for `ask`.
- **Changed host key** — the full `@@@...@@@`/"WARNING: REMOTE HOST
  IDENTIFICATION HAS CHANGED!" banner plus the trailing "Offending …
  key in `<file>:<line>`" note (`warn_changed_key()`, `sshconnect.c`
  lines 1715-1736, and `check_host_key()` lines 1342-1350) — for every
  policy except `StrictHostKeyChecking no`, which lets it through
  unconditionally (`sshconnect.c` line 1356).
- **Auth exhausted** —
  `fatal("%s@%s: Permission denied (%s).", user, host, authlist)`,
  `sshconnect2.c` line 543.
- **`known_hosts` hashed field** — `HASH_MAGIC "|1|"` + base64 salt +
  `HASH_DELIM '|'` + base64 `HMAC-SHA1(key: salt, message: hostname)`,
  salt length = `ssh_hmac_bytes(SSH_DIGEST_SHA1)` = 20 bytes
  (`hostfile.c` lines 59-60, 115-150).
- **`ssh_config` first-value-wins** — single-value keywords only take
  the first value seen across every matching `Host` block:
  `if (*activep && *intptr == -1) *intptr = value` (the `parse_time`/
  `parse_int` pattern, `readconf.c` lines 1237-1238, 1596-1597) and
  `if (*activep && *charptr == NULL) *charptr = xstrdup(arg)` for
  string options (`readconf.c` lines 1458-1459). `IdentityFile` is the
  documented exception — it accumulates across every matching block,
  unconditionally (`readconf.c` lines 1404-1422).
- **`ssh_config` default `IdentityFile` order** — real `ssh` tries
  `id_rsa`, `id_ecdsa`, `id_ecdsa_sk`, `id_ed25519`, `id_ed25519_sk`,
  then (2026-era OpenSSH) `id_mldsa44_ed25519`, in that order
  (`readconf.c` lines 2930-2941). `SSHHostConfig.defaultIdentityFiles`
  narrows this to the two types this port implements, in the same
  relative order: `id_ecdsa`, `id_ed25519`.
- **Unknown `ssh_config` keyword** —
  `fatal("%s: terminating, %d bad configuration options", filename,
  bad_options)` after the whole file is scanned (`readconf.c` lines
  2679-2681); a *recognized* keyword this port doesn't implement
  (`ForwardAgent`, `ProxyCommand`, …) is not an error
  (`readconf.c`'s own keyword table, lines 140-324).

## Android / Windows build check

Settled by this PR's own CI, across several rounds:

- **Android**: `SSHKit` (the library) is **not** added to
  `androidDroppedTargets`: it carries no `ArgumentParser` dependency
  (the only Android-specific constraint documented in
  [Android.md](Android.md)), and its other dependencies —
  `swift-nio`/`NIOCore`/`NIOPosix`, `swift-nio-ssh`, and
  `swift-crypto`'s `Crypto` — are each independently exercised on
  Android elsewhere in this graph already (`Crypto` via the `GitHub`
  target, which Android builds and tests). `SSHKitTests` **is** added
  to `androidDroppedTargets`: it links that same `Crypto` product's
  BoringSSL C++ target into its xctest bundle, which pollutes the
  Android cross-link exactly the way `GitHubTests` does (§2 in
  [Android.md](Android.md)) — the same reason `GitHubTests` is dropped
  while `GitHub` itself ships there. `build-android` is green with this
  split.
- **Windows**: `SSHKit` compiles and links cleanly — no target gating
  needed for the library. But `SSHClientTests` (in `SSHKitTests`), the
  suite that actually drives a live `NIOSSH` handshake, crashes there:
  see Phase 0 finding 7 above (`CSPRNG.swift` traps on every non-Darwin/
  Linux/Android platform). That test file is wrapped in `#if
  !os(Windows)` — `SSHKitTests`' pure-parsing suites
  (`SSHConfigTests`, `KnownHostsStoreTests`, `IdentityLoaderTests`,
  `SSHPatternListTests`, `SSHKnownHostsNameTests`) still run there, and
  `SSHClientThrowawaySSHDTests` was already macOS/Linux-only. This is a
  real functional gap, not a CI formality: `SSHClient.connect(...)`
  will trap on Windows at runtime until `apple/swift-nio-ssh` adds a
  Windows CSPRNG — tracked for the operator, not something a follow-up
  in this repo can fix.

## Test strategy

- **Unit** (every platform): `SSHConfig` parsing (`Host` patterns,
  first-value-wins, bad-option detection), `KnownHostsStore` (plain +
  hashed matching, recording), `IdentityLoader` (round-trips a real
  `ssh-keygen`-generated private key against its own `.pub` file for
  ed25519 and all three ECDSA curves).
- **Protocol-level** (every platform except Windows — see the Android /
  Windows section above): `NIOSSH`'s own server role, bootstrapped
  in-process (`Support/InProcessSSHServer.swift`) — exercises KEX,
  host-key verification (OK / new / changed, under every
  `StrictHostKeyChecking` policy), public-key auth (including
  exhaustion → `permissionDenied`), and a full exec round-trip, without
  a real OpenSSH daemon.
- **Integration** (macOS/Linux only): a throwaway, unprivileged
  `sshd(8)` on an ephemeral port with a disposable host key and a
  single `authorized_keys` entry (`Support/ThrowawaySSHD.swift`) — the
  strongest available proof of wire compatibility with real OpenSSH.
  Skips (doesn't fail) if no system `sshd`/`ssh-keygen` is present.
- **GitKitSSH, end-to-end** (macOS/Linux only, `GitKitSSHTests`): the
  same throwaway-`sshd` oracle, but driving real `Repository.clone`/
  `fetch`/`push` calls through `GitKitSSHTransportProvider` registered as
  GitKit's actual SSH transport — proving bytes flow correctly in both
  directions over the blocking bridge, not just that `SSHKit`'s own exec
  channel works. Also covers an unauthorized identity and a mismatched
  `known_hosts` entry, asserting the `Libgit2Error` each produces carries
  OpenSSH's exact wording.
