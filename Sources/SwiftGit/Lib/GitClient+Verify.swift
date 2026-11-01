import Foundation
import CGitKit
import ShellKit

// OpenPGP verification of signed tags, after git's `gpg-interface.c`
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
        /// The program's stderr, the text git shows; `nil` when the check
        /// failed before the program ran, as git leaves it.
        public var output: String?
        public var succeeded: Bool
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
        let found: (oid: String, type: String)? = try await withRepository { _ in
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
        guard let found else { return .notFound }
        guard found.type == "tag" else { return .notATag(type: found.type) }
        guard let signed = try await signedObject(found.oid) else { return .notFound }
        guard !signed.signature.isEmpty else { return .unsigned(object: signed.object) }
        return .checked(object: signed.object, try await checkSignature(signed))
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
        "-----BEGIN SIGNED MESSAGE-----", "-----BEGIN SSH SIGNATURE-----",
    ].map { Array($0.utf8) }

    /// git's `check_signature` for a tag: the signature through the
    /// OpenPGP program, then its status lines and the trust the config
    /// asks for.
    func checkSignature(_ signed: SignedObject) async throws -> SignatureCheck {
        let payload = signed.payload
        let failed = SignatureCheck(payload: payload, status: "", output: nil, succeeded: false)
        // A signature in another format is not one this port verifies;
        // never taken for a good one.
        let signature = String(decoding: signed.signature, as: UTF8.self)
        guard signature.hasPrefix("-----BEGIN PGP SIGNATURE-----")
            || signature.hasPrefix("-----BEGIN PGP MESSAGE-----")
        else {
            let format = signature.hasPrefix("-----BEGIN SSH SIGNATURE-----") ? "ssh" : "x509"
            Shell.current.stderr.write("error: \(format) signature verification is not supported\n")
            return failed
        }
        // The signer comes from the tagger header.
        let headers = String(decoding: payload, as: UTF8.self).components(separatedBy: "\n\n")[0]
        guard let tagger = headers.split(separator: "\n").first(where: { $0.hasPrefix("tagger ") }),
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
                if let level = Self.trustLevel(entry.value.uppercased()) { minimumTrust = level }
            default:
                break
            }
        }

        let run = try await runVerifier(program, payload: payload, signature: signed.signature)
        // git needs a status line to start with a newline, and a good
        // signature among them, whatever the program's exit status.
        var failure = run.failed
        let status = run.status
        failure = failure || (!status.contains("\n[GNUPG:] GOODSIG ") && !status.contains("\n[GNUPG:] EXPKEYSIG "))
        let (result, trust) = Self.parseStatus(status)
        failure = failure || (result != "G" && result != "Y") || trust < minimumTrust
        return SignatureCheck(payload: payload, status: status, output: run.output, succeeded: !failure)
    }

    /// The trust levels `gpg.minTrustLevel` and gpg's `TRUST_` lines
    /// name, in git's order.
    private static func trustLevel(_ name: String) -> Int? {
        ["UNDEFINED", "NEVER", "MARGINAL", "FULLY", "ULTIMATE"].firstIndex(of: name)
    }

    /// git's `parse_gpg_output`: the result letter and trust level the
    /// status lines give. More than one signature's result, or a trust
    /// level it doesn't know, is an error (`E`).
    private static func parseStatus(_ status: String) -> (result: Character, trust: Int) {
        let checks: [(result: Character?, prefix: String, exclusive: Bool)] = [
            ("G", "GOODSIG ", true), ("B", "BADSIG ", true), ("E", "ERRSIG ", true),
            ("X", "EXPSIG ", true), ("Y", "EXPKEYSIG ", true), ("R", "REVKEYSIG ", true),
            (nil, "VALIDSIG ", false), (nil, "TRUST_", false),
        ]
        var result: Character = "N"
        var trust = 0
        var exclusive = 0
        for raw in status.split(separator: "\n") where raw.hasPrefix("[GNUPG:] ") {
            let line = raw.dropFirst("[GNUPG:] ".count)
            guard let check = checks.first(where: { line.hasPrefix($0.prefix) }) else { continue }
            if check.exclusive {
                exclusive += 1
                if exclusive > 1 { return ("E", trust) }
            }
            if let letter = check.result { result = letter }
            if check.prefix == "TRUST_" {
                let name = line.dropFirst(check.prefix.count).prefix { $0 != " " }
                guard let level = trustLevel(String(name)) else { return ("E", trust) }
                trust = level
            }
        }
        return (result, trust)
    }

    /// What running the verifier came to.
    private struct VerifierRun {
        var failed: Bool
        var status: String
        var output: String
    }

    /// git's `verify_gpg_signed_buffer` launch: the program with
    /// `--keyid-format=long --status-fd=1 --verify <signature file> -`,
    /// the payload on its stdin. A program that can't be launched is
    /// reported as git reports it, and counts as a failed verification.
    private func runVerifier(_ program: String, payload: Data, signature: Data) async throws -> VerifierRun {
        let shell = Shell.current
        let unlaunched = VerifierRun(failed: true, status: "", output: "")
        let executable: Executable
        if program.contains("/") {
            var isDirectory: ObjCBool = false
            let url = URL(fileURLWithPath: program, relativeTo: workingDirectory)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                shell.stderr.write("fatal: cannot exec '\(program)': No such file or directory\n")
                return unlaunched
            }
            guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
                shell.stderr.write("fatal: cannot exec '\(program)': Permission denied\n")
                return unlaunched
            }
            executable = .path(url.path)
        } else {
            var reason = "No such file or directory"
            var found: String?
            let search = shell.environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            for directory in search.split(separator: ":", omittingEmptySubsequences: false) {
                let path = (directory.isEmpty ? "." : String(directory)) + "/" + program
                let url = URL(fileURLWithPath: path, relativeTo: workingDirectory)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else { continue }
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    found = url.path
                    break
                }
                reason = "Permission denied"
            }
            guard found != nil else {
                shell.stderr.write("error: cannot run \(program): \(reason)\n")
                return unlaunched
            }
            executable = .name(program)
        }

        // The program reads the signature from a file, as git writes it.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(".git_vtag_tmp" + UUID().uuidString.prefix(6))
        do {
            try signature.write(to: file)
        } catch {
            shell.stderr.write("error: could not create temporary file: \(error.localizedDescription)\n")
            return unlaunched
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let out = CapturedOutput(), err = CapturedOutput()
        do {
            let record = try await shell.processLauncher.launch(
                executable,
                arguments: Arguments(["--keyid-format=long", "--status-fd=1", "--verify", file.path, "-"]),
                environment: shell.environment,
                workingDirectory: workingDirectory.path,
                input: .data(payload),
                output: out.sink, error: err.sink)
            // Hosts that stream (SwiftBash) fill the sinks, the default
            // launcher the record too.
            let status = out.text.isEmpty ? String(decoding: record.standardOutput, as: UTF8.self) : out.text
            let output = err.text.isEmpty ? String(decoding: record.standardError, as: UTF8.self) : err.text
            return VerifierRun(failed: !record.terminationStatus.isSuccess, status: status, output: output)
        } catch let denied as ProcessLaunchDenied {
            shell.stderr.write("error: cannot run \(program): Operation not permitted (\(denied.reason))\n")
        } catch is ProcessLaunchUnsupportedOnThisPlatform {
            shell.stderr.write("error: cannot fork() for \(program): Function not implemented\n")
        } catch {
            shell.stderr.write("error: cannot run \(program): \(error.localizedDescription)\n")
        }
        return unlaunched
    }
}

/// An output sink that keeps what is written to it.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private(set) lazy var sink = OutputSink(bufferingPolicy: .bufferingOldest(0)) { [self] chunk in
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
