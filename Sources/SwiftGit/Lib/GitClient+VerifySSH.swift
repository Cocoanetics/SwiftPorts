import Foundation
import ShellKit

// SSH verification of signed tags, after git's `gpg-interface.c`
// (`verify_ssh_signed_buffer`, `parse_ssh_output`): `ssh-keygen -Y
// find-principals` names who may have signed against
// `gpg.ssh.allowedSignersFile`, `-Y verify` checks the signature for each
// of them (honouring `gpg.ssh.revocationFile`), and a signature no
// principal vouches for is still shown through `-Y check-novalidate`
// before it fails. The programs run through the shell's
// `ProcessLauncher`, so a host that can't start processes reports a
// launch failure, never a verified signature.
extension GitClient {

    /// git's `verify_ssh_signed_buffer`. `output` is `nil` when git gives
    /// up before it has anything to show.
    func runSSHVerifier(
        config: [(name: String, value: String)], payload: Data, signature: Data, timestamp: Int
    ) async -> VerifierRun {
        let shell = Shell.current
        var program = "ssh-keygen"
        var allowedSigners: String?
        var revocationFile: String?
        for entry in config {
            switch entry.name.lowercased() {
            case "gpg.ssh.program": program = Self.expandedPath(entry.value, shell: shell)
            case "gpg.ssh.allowedsignersfile": allowedSigners = Self.expandedPath(entry.value, shell: shell)
            case "gpg.ssh.revocationfile": revocationFile = Self.expandedPath(entry.value, shell: shell)
            default: break
            }
        }
        guard let allowedSigners else {
            shell.stderr.write(
                "error: gpg.ssh.allowedSignersFile needs to be configured and exist for ssh signature verification\n")
            return VerifierRun(failed: true, status: "", output: nil)
        }
        guard let file = writeSignatureFile(signature) else {
            return VerifierRun(failed: true, status: "", output: nil)
        }
        defer { try? FileManager.default.removeItem(at: file) }

        // The time the signature is checked at: when it was made, in the
        // local timezone, as ssh-keygen's key validity has none.
        var verifyTime = ""
        if timestamp != 0 {
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = .current
            format.dateFormat = "yyyyMMddHHmmss"
            verifyTime = "-Overify-time=" + format.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        }

        let principals = await launch(
            program, ["-Y", "find-principals", "-f", allowedSigners, "-s", file.path, verifyTime], input: Data())
        if let principals, !principals.succeeded, principals.stderr.contains("usage:") {
            shell.stderr.write("error: ssh-keygen -Y find-principals/verify is needed for ssh signature "
                + "verification (available in openssh version 8.2p1+)\n")
            return VerifierRun(failed: true, status: "", output: nil)
        }
        let principalsError = principals?.stderr ?? ""
        var verified: ProgramRun?
        var succeeded = false
        if let principals, principals.succeeded, !principals.stdout.isEmpty {
            // Every principal found (one per line) is tried until one matches.
            for var line in principals.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasSuffix("\r") { line = line.dropLast() }
                guard !line.isEmpty else { continue }
                var arguments = ["-Y", "verify", "-n", "git", "-f", allowedSigners, "-I", String(line),
                                 "-s", file.path, verifyTime]
                if let revocationFile {
                    if FileManager.default.fileExists(atPath: URL(fileURLWithPath: revocationFile,
                                                                  relativeTo: workingDirectory).path) {
                        arguments += ["-r", revocationFile]
                    } else {
                        shell.stderr.write(
                            "warning: ssh signing revocation file configured but not found: \(revocationFile)\n")
                    }
                }
                verified = await launch(program, arguments, input: payload)
                if let verified, verified.succeeded, verified.stdout.hasPrefix("Good") {
                    succeeded = true
                    break
                }
            }
        } else {
            // No principal vouches for it: shown anyway, then failed.
            verified = await launch(
                program, ["-Y", "check-novalidate", "-n", "git", "-s", file.path, verifyTime], input: payload)
        }
        let output = Self.stripspace(verified?.stdout ?? "") + principalsError + Self.stripspace(verified?.stderr ?? "")
        return VerifierRun(failed: !succeeded, status: output, output: output)
    }

    /// git's `parse_ssh_output`: `ssh-keygen`'s first line as a result
    /// letter and trust level. A known principal is fully trusted, a good
    /// signature of an unknown key undefined, anything else bad.
    static func parseSSHOutput(_ output: String) -> (result: Character, trust: Int) {
        var line = Substring(output.prefix { $0 != "\n" })
        let bad: (Character, Int) = ("B", 1)
        var trust: Int
        if line.hasPrefix("Good \"git\" signature for ") {
            line = line.dropFirst("Good \"git\" signature for ".count)
            // The last " with " ends the principal, which may hold spaces.
            guard let with = line.ranges(of: " with ").last else { return bad }
            line = line[line.index(after: with.lowerBound)...]
            trust = 3
        } else if line.hasPrefix("Good \"git\" signature with ") {
            line = line.dropFirst("Good \"git\" signature with ".count)
            trust = 0
        } else {
            return bad
        }
        return line.contains("key ") ? ("G", trust) : bad
    }

    /// git's `strbuf_stripspace` without comments: trailing whitespace
    /// off each line, blank runs collapsed to one line, none leading or
    /// trailing, and a non-empty result ends with a newline.
    static func stripspace(_ text: String) -> String {
        var lines: [Substring] = []
        var blank = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw
            while let last = line.last, last.isWhitespace { line = line.dropLast() }
            if line.isEmpty {
                blank = !lines.isEmpty
            } else {
                if blank { lines.append("") }
                blank = false
                lines.append(line)
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// git's `git_config_pathname` (`interpolate_path`): a leading `~/` is
    /// the shell's HOME, `~user/` that user's home, `%(prefix)/` git's
    /// install prefix (`/usr`, there being no git install of our own).
    /// Anything else, or a user that doesn't exist, stays as written.
    private static func expandedPath(_ path: String, shell: Shell) -> String {
        if path.hasPrefix("%(prefix)/") { return "/usr" + path.dropFirst("%(prefix)".count) }
        guard path.hasPrefix("~") else { return path }
        let slash = path.firstIndex(of: "/") ?? path.endIndex
        let user = path[path.index(after: path.startIndex)..<slash]
        let rest = path[slash...]
        if user.isEmpty {
            guard let home = shell.environment["HOME"] else { return path }
            return home + rest
        }
        #if os(Windows) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS) || os(Android)
        return path
        #else
        guard let entry = getpwnam(String(user)), let directory = entry.pointee.pw_dir else { return path }
        return String(cString: directory) + rest
        #endif
    }
}
