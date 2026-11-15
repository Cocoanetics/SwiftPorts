import Foundation
import GitKit
import ShellKit

// Signing commits and tags, after git's `gpg-interface.c` (`sign_buffer`,
// `sign_buffer_gpg`, `sign_buffer_ssh`, `get_signing_key`,
// `get_default_ssh_signing_key`), `builtin/commit.c` (`commit.gpgsign`)
// and `builtin/tag.c` (`tag.gpgsign`, `tag.forceSignAnnotated`). Whether
// to sign is decided here and handed to GitKit as an explicit `SignMode`;
// the signature itself is made by ``ShellSigner``.
extension GitClient {

    /// Signing failed, as git reports it. What git said on the way is
    /// already on the shell's stderr; `fatal` is set when git dies at
    /// that point (`fatal: <fatal>`), and `nil` when it goes on to fail
    /// the write itself. Uncaught, it ends the command as `git commit`
    /// and `git merge` end, `fatal: failed to write commit object`;
    /// `cherry-pick`, `rebase` and `tag` say their own words.
    public struct SigningFailure: Error, Sendable, CustomStringConvertible, CommandFailure {
        public let fatal: String?

        public var description: String { fatal ?? "failed to write commit object" }

        public var diagnostic: String { "fatal: \(description)\n" }

        public var exitStatus: ExitStatus { ExitStatus(128) }
    }

    /// The signing config git's `git_gpg_config` reads, from the same
    /// config stack as everything else (`-c`, `GIT_CONFIG_*`).
    struct SigningSettings: Sendable {
        var format: SigningFormat
        var program: String
        var signingKey: String?
        var defaultKeyCommand: String?

        init(in directory: URL) throws {
            let entry = try GitClient.configEntry("gpg.format", in: directory)
            let value = entry == nil ? "openpgp" : entry ?? nil
            guard let value, let format = SigningFormat(rawValue: value) else {
                Shell.current.stderr.write("error: invalid value for 'gpg.format': '\(value ?? "")'\n")
                throw SigningFailure(fatal: "bad config variable 'gpg.format'")
            }
            self.format = format
            let programs: String
            switch format {
            case .openpgp: programs = #"^gpg\.(openpgp\.)?program$"#
            case .x509: programs = #"^gpg\.x509\.program$"#
            case .ssh: programs = #"^gpg\.ssh\.program$"#
            }
            program = try GitClient.configValues(matching: programs, in: directory).last
                ?? ["openpgp": "gpg", "x509": "gpgsm", "ssh": "ssh-keygen"][format.rawValue]!
            signingKey = try GitClient.configEntry("user.signingkey", in: directory) ?? nil
            defaultKeyCommand = try GitClient.configEntry("gpg.ssh.defaultKeyCommand", in: directory) ?? nil
        }
    }

    /// git's choice for a commit: `sign` when given (`-S[<key>]`,
    /// `--no-gpg-sign`), else `commit.gpgsign`.
    func resolvedCommitSignMode(_ sign: SignMode) throws -> SignMode {
        guard sign == .config else { return sign }
        guard let entry = try Self.configEntry("commit.gpgsign", in: workingDirectory),
              try Self.parseGitBool(entry, key: "commit.gpgsign")
        else { return .noSign }
        return .sign(keyID: nil)
    }

    /// git tag's choice: `-u <key>` always signs; otherwise `-s` /
    /// `--no-sign` (`sign`), else `tag.gpgsign`. An annotated tag made
    /// without `-a` (only `-m`) is signed with `tag.forceSignAnnotated`.
    /// `.noSign` with neither `annotate` nor `message` is a lightweight
    /// tag.
    public func tagSignMode(sign: Bool?, keyID: String?, annotate: Bool, message: Bool) async throws -> SignMode {
        try await withRepository { _ in
            if let keyID { return .sign(keyID: keyID) }
            func flag(_ key: String) throws -> Bool {
                try Self.configEntry(key, in: workingDirectory).map { try Self.parseGitBool($0, key: key) } ?? false
            }
            var signs = try sign ?? flag("tag.gpgsign")
            if !signs, message, !annotate { signs = try flag("tag.forceSignAnnotated") }
            return signs ? .sign(keyID: nil) : .noSign
        }
    }

    /// git's `sign_buffer` for `payload` with `key` (`nil`: git's
    /// `get_signing_key` default), the armored signature it gives.
    func signBuffer(
        _ payload: [UInt8], key: String?, identity: String, settings: SigningSettings
    ) async throws -> String {
        switch settings.format {
        case .ssh:
            var key = key
            if key == nil { key = try await defaultSSHKey(settings) }
            return try await signSSH(payload, key: key, program: settings.program)
        case .openpgp, .x509:
            return try await signGPG(payload, key: key ?? identity, program: settings.program)
        }
    }

    /// `sign_buffer_gpg`: `<program> --status-fd=2 -bsau <key>`, the
    /// payload on stdin and the signature on stdout, good only with a
    /// `SIG_CREATED` status line.
    private func signGPG(_ payload: [UInt8], key: String, program: String) async throws -> String {
        let run = await launch(program, ["--status-fd=2", "-bsau", key], input: Data(payload))
        let status = run?.stderr ?? ""
        let created = status.hasPrefix("[GNUPG:] SIG_CREATED ") || status.contains("\n[GNUPG:] SIG_CREATED ")
        guard let run, run.succeeded, created else {
            Shell.current.stderr.write(
                "error: gpg failed to sign the data:\n\(status.isEmpty ? "(no gpg output)" : status)\n")
            throw SigningFailure(fatal: nil)
        }
        return run.stdout.replacingOccurrences(of: "\r", with: "")
    }

    /// `sign_buffer_ssh`: `<program> -Y sign -n git -f <key file> [-U]
    /// <buffer file>`, the signature read from `<buffer file>.sig`. A
    /// literal key (`key::…`, or the deprecated bare `ssh-…`) goes into a
    /// temporary file of its own; a path has `~` expanded against the
    /// shell's home.
    private func signSSH(_ payload: [UInt8], key: String?, program: String) async throws -> String {
        let stderr = Shell.current.stderr
        guard let key, !key.isEmpty else {
            stderr.write("error: user.signingKey needs to be set for ssh signing\n")
            throw SigningFailure(fatal: nil)
        }
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }

        let literal = Self.literalSSHKey(key)
        let keyPath: String
        if let literal {
            guard let file = await writeTemporaryFile(".git_signing_key_tmp", Data(literal.utf8)) else {
                throw SigningFailure(fatal: nil)
            }
            files.append(file)
            keyPath = Shell.current.displayPath(for: file)
        } else {
            keyPath = Self.expandedPath(key, shell: Shell.current)
        }
        guard let buffer = await writeTemporaryFile(".git_signing_buffer_tmp", Data(payload)) else {
            throw SigningFailure(fatal: nil)
        }
        let signatureFile = buffer.appendingPathExtension("sig")
        files += [buffer, signatureFile]

        var arguments = ["-Y", "sign", "-n", "git", "-f", keyPath]
        if literal != nil { arguments.append("-U") }
        arguments.append(Shell.current.displayPath(for: buffer))
        let run = await launch(program, arguments, input: Data())
        guard let run, run.succeeded else {
            let output = run?.stderr ?? ""
            if output.contains("usage:") {
                stderr.write("error: ssh-keygen -Y sign is needed for ssh signing "
                    + "(available in openssh version 8.2p1+)\n")
            }
            stderr.write("error: \(output)\n")
            throw SigningFailure(fatal: nil)
        }
        do {
            try await Shell.authorize(signatureFile)
            let signature = try Data(contentsOf: signatureFile)
            return String(decoding: signature, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        } catch {
            stderr.write("error: failed reading ssh signing data buffer from '\(signatureFile.path)': "
                + "\(error.localizedDescription)\n")
            throw SigningFailure(fatal: nil)
        }
    }

    /// `get_default_ssh_signing_key`: the first line of what
    /// `gpg.ssh.defaultKeyCommand` prints, when it's a literal key.
    private func defaultSSHKey(_ settings: SigningSettings) async throws -> String? {
        guard let command = settings.defaultKeyCommand else {
            throw SigningFailure(fatal: "either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured")
        }
        let words = Self.splitCommandLine(command)
        guard let program = words.first else {
            throw SigningFailure(fatal: "malformed build-time gpg.ssh.defaultKeyCommand: empty command")
        }
        let run = await launch(program, Array(words.dropFirst()), input: Data())
        let stdout = run?.stdout ?? "", output = run?.stderr ?? ""
        guard let run, run.succeeded else {
            Shell.current.stderr.write("warning: gpg.ssh.defaultKeyCommand failed: \(output) \(stdout)\n")
            return nil
        }
        // strbuf_split_max keeps the line's newline, as git's key does.
        let line = stdout.firstIndex(of: "\n").map { String(stdout[...$0]) } ?? stdout
        guard Self.literalSSHKey(line) != nil else {
            Shell.current.stderr.write(
                "warning: gpg.ssh.defaultKeyCommand succeeded but returned no keys: \(output) \(stdout)\n")
            return nil
        }
        return line
    }

    /// git's `is_literal_ssh_key`: the key itself after `key::`, or a
    /// whole `ssh-…` value; `nil` for a path.
    static func literalSSHKey(_ key: String) -> String? {
        if key.hasPrefix("key::") { return String(key.dropFirst("key::".count)) }
        return key.hasPrefix("ssh-") ? key : nil
    }

    /// git's `split_cmdline`: words split at whitespace, with single and
    /// double quotes (a backslash escaping inside double quotes) holding
    /// them together.
    static func splitCommandLine(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                word.append(character)
                escaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaped = true
                } else {
                    word.append(character)
                }
            } else if character.isWhitespace {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else {
                word.append(character)
                inWord = true
            }
        }
        if inWord { words.append(word) }
        return words
    }
}
