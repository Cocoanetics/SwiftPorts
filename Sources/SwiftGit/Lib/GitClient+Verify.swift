import Foundation
import CGitKit
import ShellKit

// OpenPGP (and, in `GitClient+VerifySSH.swift`, SSH) verification of signed tags, after git's `gpg-interface.c`
// (`parse_signature`, `check_signature`, `verify_gpg_signed_buffer`) and
// `tag.c` (`gpg_verify_tag`). The signature goes through the configured
// OpenPGP program (`gpg.program` / `gpg.openpgp.program`), launched
// through the shell's `ProcessLauncher`, so a sandbox that refuses
// processes refuses verification too, and says so, as git does for a
// program it can't run.
extension GitClient {

    /// What checking one signature came to: the signed `payload`, the
    /// program's status lines (`--status-fd=1`) and its diagnostics, and
    /// whether git counts the signature as good.
    public struct SignatureCheck: Sendable {
        public var payload: Data
        /// The program's status lines; empty when it never ran.
        public var status: String
        /// The program's stderr, the text git shows: empty when it could
        /// not be launched, `nil` when the check failed before a launch
        /// was tried (no tagger, another format), as git leaves it.
        public var output: String?
        public var succeeded: Bool
        /// git's result letter for the signature (`G`, `B`, `E`, `X`,
        /// `Y`, `R`), `N` when there is none to tell.
        public var result: Character = "N"
        /// Who signed: the uid gpg names, the principal ssh-keygen found.
        public var signer: String?
        /// The key: gpg's long key id, an SSH key's fingerprint.
        public var key: String?
        public var fingerprint: String?
        /// The primary key's fingerprint, which only OpenPGP gives.
        public var primaryKeyFingerprint: String?
        /// The trust level as an index into ``trustLevels``.
        var trust = 0

        /// `undefined`, `never`, `marginal`, `fully` or `ultimate`, as
        /// git's `%GT` names the trust in the key.
        public var trustLevel: String { trustLevels[trust].lowercased() }

        /// No signature: what git's `%G` placeholders show for an
        /// unsigned commit.
        public static let unsigned = SignatureCheck(payload: Data(), status: "", output: nil, succeeded: false)

        /// What `%G?` shows: the result letter, with a good signature of
        /// a key trusted `undefined` or `never` as `U`.
        public var verdict: Character {
            result == "G" && trust < 2 ? "U" : result
        }
    }

    /// One tag object, split as git's `parse_signature` splits it.
    struct SignedObject {
        /// The whole object.
        var object: Data
        /// What the signature covers, with the signature taken off.
        var payload: Data
        /// From the signature's first line on; empty when unsigned.
        var signature: Data
    }

    /// What `git verify-tag` / `git tag -v` finds out about one tag.
    public enum TagVerification: Sendable {
        /// Nothing resolves to `name`.
        case notFound
        /// `name` is an object of `type`, not a tag.
        case notATag(type: String)
        /// A tag object with no signature; `object` is what it holds.
        case unsigned(object: Data)
        /// A signed tag and the check of its signature.
        case checked(object: Data, SignatureCheck)

        public var succeeded: Bool {
            if case .checked(_, let check) = self { return check.succeeded }
            return false
        }
    }

    /// Verify the signature of tag `name`, as `git verify-tag` does, or,
    /// with `inTagNamespace`, as `git tag -v` (only `refs/tags/<name>`).
    public func verifyTag(_ name: String, inTagNamespace: Bool = false) async throws -> TagVerification {
        let spec = inTagNamespace ? "refs/tags/" + name : name
        guard let found = try await lookUpObject(spec) else { return .notFound }
        guard found.type == "tag" else { return .notATag(type: found.type) }
        guard let signed = try await signedObject(found.oid) else { return .notFound }
        guard !signed.signature.isEmpty else { return .unsigned(object: signed.object) }
        return .checked(object: signed.object, try await checkSignature(signed))
    }

    /// The object `spec` names and its type (`commit`, `tag`, …); `nil`
    /// when it names none.
    func lookUpObject(_ spec: String) async throws -> (oid: String, type: String)? {
        try await withRepository { _ in
            var repo: OpaquePointer?
            var object: OpaquePointer?
            defer {
                git_object_free(object)
                git_repository_free(repo)
            }
            try Self.check(git_repository_open_ext(&repo, workingDirectory.path, 0, nil))
            guard git_revparse_single(&object, repo, spec) == 0, let object else { return nil }
            let oid = git_object_id(object).map { String(cString: git_oid_tostr_s($0)) } ?? ""
            return (oid, String(cString: git_object_type2string(git_object_type(object))))
        }
    }

    /// Tag object `oid` split into payload and signature; `nil` when
    /// `oid` can't be read as an object.
    func signedObject(_ oid: String) async throws -> SignedObject? {
        let object: Data? = try await withRepository { _ in
            var repo: OpaquePointer?
            var odb: OpaquePointer?
            var object: OpaquePointer?
            defer {
                git_odb_object_free(object)
                git_odb_free(odb)
                git_repository_free(repo)
            }
            try Self.check(git_repository_open_ext(&repo, workingDirectory.path, 0, nil))
            try Self.check(git_repository_odb(&odb, repo))
            var id = git_oid()
            guard git_oid_fromstr(&id, oid) == 0, git_odb_read(&object, odb, &id) == 0,
                  let bytes = git_odb_object_data(object)
            else { return nil }
            return Data(bytes: bytes, count: git_odb_object_size(object))
        }
        guard let object else { return nil }
        let bytes = [UInt8](object)
        // git's parse_signed_buffer: the last line that opens a signature.
        var start = 0
        var match = bytes.count
        while start < bytes.count {
            if Self.signatureMarkers.contains(where: { bytes[start...].starts(with: $0) }) { match = start }
            start = bytes[start...].firstIndex(of: 0x0A).map { $0 + 1 } ?? bytes.count
        }
        guard match != bytes.count else { return SignedObject(object: object, payload: object, signature: Data()) }
        return SignedObject(
            object: object, payload: Data(bytes[..<match]), signature: Data(bytes[match...]))
    }

    private static let signatureMarkers: [[UInt8]] = [
        "-----BEGIN PGP SIGNATURE-----", "-----BEGIN PGP MESSAGE-----",
        "-----BEGIN SIGNED MESSAGE-----", "-----BEGIN SSH SIGNATURE-----"
    ].map { Array($0.utf8) }

    /// git's `check_signature` for a tag (or, with `identity`
    /// `committer`, a commit): the signature through the OpenPGP program,
    /// then its status lines and the trust the config asks for.
    func checkSignature(_ signed: SignedObject, identity: String = "tagger") async throws -> SignatureCheck {
        let payload = signed.payload
        let failed = SignatureCheck(payload: payload, status: "", output: nil, succeeded: false)
        // The signer comes from the tagger (committer) header.
        let headers = String(decoding: payload, as: UTF8.self).components(separatedBy: "\n\n")[0]
        let signature = String(decoding: signed.signature, as: UTF8.self)
        let isSSH = signature.hasPrefix("-----BEGIN SSH SIGNATURE-----")
        // An x509 signature is not one this port verifies; never taken
        // for a good one.
        if !isSSH && !signature.hasPrefix("-----BEGIN PGP SIGNATURE-----")
            && !signature.hasPrefix("-----BEGIN PGP MESSAGE-----") {
            Shell.current.stderr.write("error: x509 signature verification is not supported\n")
            return failed
        }
        guard let tagger = headers.split(separator: "\n").first(where: { $0.hasPrefix(identity + " ") }),
              let open = tagger.firstIndex(of: "<"), tagger[open...].contains(">")
        else { return failed }

        let config = try await configList()
        var program = "gpg"
        var minimumTrust = 0
        for entry in config {
            switch entry.name.lowercased() {
            case "gpg.program", "gpg.openpgp.program":
                program = entry.value
            case "gpg.mintrustlevel":
                guard let level = Self.trustLevel(entry.value.uppercased()) else {
                    throw Libgit2Error(code: -1, klass: 0,
                        message: "unsupported value for gpg.minTrustLevel: \(entry.value)")
                }
                minimumTrust = level
            default:
                break
            }
        }

        if isSSH {
            let timestamp = tagger[tagger.index(after: tagger[open...].firstIndex(of: ">")!)...]
                .split(separator: " ").first.flatMap { Int($0) } ?? 0
            let run = await runSSHVerifier(config: config, payload: payload, signature: signed.signature,
                                           timestamp: timestamp)
            guard let output = run.output else {
                return SignatureCheck(payload: payload, status: "", output: nil, succeeded: false)
            }
            var check = SignatureCheck(payload: payload, status: output, output: output, succeeded: false)
            Self.parseSSHOutput(output, into: &check)
            let bad = check.result != "G" && check.result != "Y"
            check.succeeded = !(run.failed || bad || check.trust < minimumTrust)
            return check
        }
        let run = try await runVerifier(program, payload: payload, signature: signed.signature)
        // git needs a status line to start with a newline, and a good
        // signature among them, whatever the program's exit status.
        var failure = run.failed
        let status = run.status
        failure = failure || (!status.contains("\n[GNUPG:] GOODSIG ") && !status.contains("\n[GNUPG:] EXPKEYSIG "))
        var check = SignatureCheck(payload: payload, status: status, output: run.output, succeeded: false)
        Self.parseStatus(status, into: &check)
        check.succeeded = !(failure || (check.result != "G" && check.result != "Y") || check.trust < minimumTrust)
        return check
    }

    /// The trust levels `gpg.minTrustLevel` and gpg's `TRUST_` lines
    /// name, in git's order.
    private static func trustLevel(_ name: String) -> Int? {
        trustLevels.firstIndex(of: name)
    }

    /// git's `parse_gpg_output`: the result letter, key, signer,
    /// fingerprints and trust level the status lines give. More than one
    /// signature's result, or a trust level it doesn't know, is an error
    /// (`E`), with nothing else kept.
    private static func parseStatus(_ status: String, into check: inout SignatureCheck) {
        // The result each status gives, whether it is a signature's one
        // result (and so a key id, and, but for ERRSIG, the uid follows).
        let statuses: [(result: Character?, prefix: String, exclusive: Bool)] = [
            ("G", "GOODSIG ", true), ("B", "BADSIG ", true), ("E", "ERRSIG ", true),
            ("X", "EXPSIG ", true), ("Y", "EXPKEYSIG ", true), ("R", "REVKEYSIG ", true),
            (nil, "VALIDSIG ", false), (nil, "TRUST_", false)
        ]
        var exclusive = 0
        for raw in status.split(separator: "\n") where raw.hasPrefix("[GNUPG:] ") {
            let line = raw.dropFirst("[GNUPG:] ".count)
            guard let match = statuses.first(where: { line.hasPrefix($0.prefix) }) else { continue }
            let rest = line.dropFirst(match.prefix.count)
            if match.exclusive {
                exclusive += 1
                if exclusive > 1 { return check.failParsing() }
            }
            if let letter = match.result { check.result = letter }
            if match.exclusive {
                let fields = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                check.key = String(fields[0])
                if match.prefix != "ERRSIG ", fields.count > 1 { check.signer = String(fields[1]) }
            }
            if match.prefix == "TRUST_" {
                guard let level = trustLevel(String(rest.prefix { $0 != " " })) else { return check.failParsing() }
                check.trust = level
            }
            if match.prefix == "VALIDSIG " {
                // The primary key's fingerprint is the tenth field, when
                // there is one.
                let fields = rest.split(separator: " ", omittingEmptySubsequences: false)
                check.fingerprint = String(fields[0])
                check.primaryKeyFingerprint = fields.count > 9 ? fields[9...].joined(separator: " ") : nil
            }
        }
    }

    /// What running the verifier came to.
    struct VerifierRun {
        var failed: Bool
        var status: String
        var output: String?
    }

    /// git's `verify_gpg_signed_buffer` launch: the program with
    /// `--keyid-format=long --status-fd=1 --verify <signature file> -`,
    /// the payload on its stdin. A program that can't be launched is
    /// reported as git reports it, and counts as a failed verification
    /// with nothing said by the program: git's output is empty then, and
    /// a merge message gets no `gpg verification failed.` line.
    private func runVerifier(_ program: String, payload: Data, signature: Data) async throws -> VerifierRun {
        let unlaunched = VerifierRun(failed: true, status: "", output: "")
        guard let file = await writeSignatureFile(signature) else {
            return VerifierRun(failed: true, status: "", output: nil)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let run = await launch(
            program, ["--keyid-format=long", "--status-fd=1", "--verify", file.path, "-"], input: payload)
        else { return unlaunched }
        return VerifierRun(failed: !run.succeeded, status: run.stdout, output: run.stderr)
    }

    /// The detached signature in a temporary file, as git writes it for
    /// the program to read; `nil` (and said) when it can't be written,
    /// where git gives up before any program runs.
    func writeSignatureFile(_ signature: Data) async -> URL? {
        await writeTemporaryFile(".git_vtag_tmp", signature)
    }

    /// `data` in a new temporary file named as git's `mks_tempfile_t`
    /// names one (`prefix` and six random characters), in the shell's
    /// temporary directory and through its sandbox; `nil` (and said)
    /// when it can't be written.
    func writeTemporaryFile(_ prefix: String, _ data: Data) async -> URL? {
        let file = Shell.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString.prefix(6))
        do {
            try await Shell.authorize(file)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        } catch {
            Shell.current.stderr.write("error: could not create temporary file: \(error.localizedDescription)\n")
            return nil
        }
    }

    /// What one launched program printed and whether it exited 0.
    struct ProgramRun {
        var succeeded: Bool
        var stdout: String
        var stderr: String
    }

    /// git's `pipe_command` for `program`: found as git finds it (a path
    /// as given, a bare name on the shell's `PATH`) and launched through
    /// the shell's `ProcessLauncher`. `nil`, with git's message on
    /// stderr, when it can't be started.
    func launch(_ program: String, _ arguments: [String], input: Data) async -> ProgramRun? {
        let shell = Shell.current
        let executable: Executable
        var registeredCommand = false
        #if os(Windows)
        let separators: Set<Character> = ["/", "\\"]
        let pathSeparator: Character = ";"
        #else
        let separators: Set<Character> = ["/"]
        let pathSeparator: Character = ":"
        #endif
        if program.contains(where: separators.contains) {
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: program, relativeTo: workingDirectory)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                shell.stderr.write("fatal: cannot exec '\(program)': No such file or directory\n")
                return nil
            }
            guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
                shell.stderr.write("fatal: cannot exec '\(program)': Permission denied\n")
                return nil
            }
            executable = .path(url.path)
        } else if shell.commands[program] != nil {
            executable = .name(program)
            registeredCommand = true
        } else {
            var reason = "No such file or directory"
            var found: String?
            let search = shell.environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            #if os(Windows)
            // A bare `gpg` is `gpg.exe` on Windows: PATHEXT's suffixes are
            // tried after the name as given, as the launcher will.
            let pathext = shell.environment["PATHEXT"] ?? ProcessInfo.processInfo.environment["PATHEXT"]
            let suffixes = [""] + (pathext ?? ".COM;.EXE;.BAT;.CMD").split(separator: ";").map(String.init)
            #else
            let suffixes = [""]
            #endif
            directories: for directory in search.split(separator: pathSeparator, omittingEmptySubsequences: false) {
                for suffix in suffixes {
                    let path = (directory.isEmpty ? "." : String(directory)) + "/" + program + suffix
                    let url = URL(fileURLWithPath: path, relativeTo: workingDirectory)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue
                    else { continue }
                    if FileManager.default.isExecutableFile(atPath: url.path) {
                        found = url.path
                        break directories
                    }
                    reason = "Permission denied"
                }
            }
            guard found != nil else {
                shell.stderr.write("error: cannot run \(program): \(reason)\n")
                return nil
            }
            executable = .name(program)
        }

        let out = CapturedOutput(), err = CapturedOutput()
        do {
            let record = try await shell.processLauncher.launch(
                executable,
                arguments: Arguments(arguments),
                environment: shell.environment,
                workingDirectory: registeredCommand
                    ? shell.displayPath(for: workingDirectory)
                    : workingDirectory.path,
                input: .data(input),
                output: out.sink, error: err.sink)
            // Hosts that stream (SwiftBash) fill the sinks, the default
            // launcher the record too.
            let stdout = out.text.isEmpty ? String(decoding: record.standardOutput, as: UTF8.self) : out.text
            let stderr = err.text.isEmpty ? String(decoding: record.standardError, as: UTF8.self) : err.text
            return ProgramRun(succeeded: record.terminationStatus.isSuccess, stdout: stdout, stderr: stderr)
        } catch let denied as ProcessLaunchDenied {
            shell.stderr.write("error: cannot run \(program): Operation not permitted (\(denied.reason))\n")
        } catch is ProcessLaunchUnresolved {
            // Nothing in the shell runs it, and the host never does: git's
            // missing program.
            if program.contains(where: separators.contains) {
                shell.stderr.write("fatal: cannot exec '\(program)': No such file or directory\n")
            } else {
                shell.stderr.write("error: cannot run \(program): No such file or directory\n")
            }
        } catch is ProcessLaunchUnsupportedOnThisPlatform {
            shell.stderr.write("error: cannot fork() for \(program): Function not implemented\n")
        } catch {
            shell.stderr.write("error: cannot run \(program): \(error.localizedDescription)\n")
        }
        return nil
    }
}

/// gpg's trust levels (its `TRUST_` lines), in git's order.
let trustLevels = ["UNDEFINED", "NEVER", "MARGINAL", "FULLY", "ULTIMATE"]

extension GitClient.SignatureCheck {
    /// What git's `parse_gpg_output` keeps of status lines it refuses:
    /// an error, and nothing about who or which key.
    fileprivate mutating func failParsing() {
        result = "E"
        signer = nil
        key = nil
        fingerprint = nil
        primaryKeyFingerprint = nil
    }
}

/// An output sink that keeps what is written to it.
final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    // Weak: the sink keeps this closure for its lifetime, and `self`
    // keeps the sink, so a strong capture would never be freed.
    private(set) lazy var sink = OutputSink(bufferingPolicy: .bufferingOldest(0)) { [weak self] chunk in
        self?.append(chunk)
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
