# SSH

In-process, OpenSSH-compatible SSH client on mainline
[apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh). Issue
[#111](https://github.com/Cocoanetics/SwiftPorts/issues/111)'s Phase 1:
`SSHKit` (library only). `SSHCommand`/`ssh` and the GitKit SSH transport
land in follow-up issues (#114, #113).

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

Only `SSHKit` (target name matches the umbrella folder, per AGENTS.md's
naming convention) ships today — no `SSHCommand`/`ssh` executable yet.

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

No CI access from this session to actually run
`skiptools/swift-android-action` or the Windows job — the check the
plan asks for happens on this PR's own CI run. `SSHKit` is **not**
pre-emptively added to `androidDroppedTargets` in `Package.swift`: it
carries no `ArgumentParser` dependency (the only Android-specific
constraint documented in [Android.md](Android.md)), and its other
dependencies — `swift-nio`/`NIOCore`/`NIOPosix`, `swift-nio-ssh`, and
`swift-crypto`'s `Crypto` — are each independently exercised on Android
elsewhere in this graph already (`Crypto` via the `GitHub` target,
which Android builds and tests). If CI shows `swift-nio`/`swift-nio-ssh`
don't cross-compile for Android or Windows as-is, gate `SSHKit` and
`SSHKitTests` in `androidDroppedTargets` (or add a Windows-specific
carve-out) as a follow-up — the layout keeps this a one-target, additive
change since nothing else in the repo depends on `SSHKit` yet.

## Test strategy

- **Unit** (every platform): `SSHConfig` parsing (`Host` patterns,
  first-value-wins, bad-option detection), `KnownHostsStore` (plain +
  hashed matching, recording), `IdentityLoader` (round-trips a real
  `ssh-keygen`-generated private key against its own `.pub` file for
  ed25519 and all three ECDSA curves).
- **Protocol-level** (every platform, including Windows/iOS/Android):
  `NIOSSH`'s own server role, bootstrapped in-process
  (`Support/InProcessSSHServer.swift`) — exercises KEX, host-key
  verification (OK / new / changed, under every `StrictHostKeyChecking`
  policy), public-key auth (including exhaustion → `permissionDenied`),
  and a full exec round-trip, without a real OpenSSH daemon.
- **Integration** (macOS/Linux only): a throwaway, unprivileged
  `sshd(8)` on an ephemeral port with a disposable host key and a
  single `authorized_keys` entry (`Support/ThrowawaySSHD.swift`) — the
  strongest available proof of wire compatibility with real OpenSSH.
  Skips (doesn't fail) if no system `sshd`/`ssh-keygen` is present.
