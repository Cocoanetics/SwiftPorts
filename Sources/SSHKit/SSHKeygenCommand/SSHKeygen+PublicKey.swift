import Foundation
import ShellKit
import SSHKit

extension SSHKeygenExecutable {
    static func publicKey(
        _ args: SSHKeygenArguments, stdin: InputSource, stdout: OutputSink, prompt: @escaping PassphrasePrompt
    ) async throws -> Int32 {
        var path = args["f"] ?? ""
        if args["f"] == nil {
            let defaultPath = (Shell.current.environment["HOME"] ?? "") + "/.ssh/id_ed25519"
            stdout.write("Enter file in which the key is (\(defaultPath)): ")
            path = await stdin.readLine() ?? ""
            if path.isEmpty { path = defaultPath }
        }
        let data = try await read(path)
        if args.flags.contains("l") {
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isNewline })
            let fingerprints = lines.compactMap { fingerprint(for: String($0)) }
            if !fingerprints.isEmpty {
                fingerprints.forEach { stdout.write($0 + "\n") }
                return 0
            }
        }
        let key: SSHPublicKey
        let comment: String
        if args.flags.contains("l"),
           let publicKey = try? SSHPublicKey(openSSHPrivateKeyFile: String(decoding: data, as: UTF8.self)) {
            key = publicKey
            let sibling = try? await read(path + ".pub")
            if let sibling, let parsed = try? SSHPublicKey(openSSHLine: String(decoding: sibling, as: UTF8.self)),
               parsed == key {
                let parts = String(decoding: sibling, as: UTF8.self)
                    .split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
                comment = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .newlines) : "no comment"
            } else {
                let loaded = try? await IdentityLoader.loadKey(path: path, passphrasePrompt: { _ in nil })
                comment = loaded?.comment ?? "no comment"
            }
        } else {
            let privateKey = try await loadPrivateKey(path, prompt: prompt)
            key = privateKey.publicKey
            comment = privateKey.comment
        }
        if args.flags.contains("l") {
            stdout.write("\(key.bits) \(key.sha256Fingerprint) "
                + "\(comment.isEmpty ? "no comment" : comment) (\(key.shortTypeName))\n")
        } else { stdout.write(key.openSSHLine(comment: comment) + "\n") }
        return 0
    }

    private static func fingerprint(for line: String) -> String? {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard !fields.isEmpty, fields[0].first != "#" else { return nil }
        for index in fields.indices.dropLast() {
            guard let key = try? SSHPublicKey(openSSHLine: "\(fields[index]) \(fields[index + 1])") else {
                continue
            }
            let commentIndex = fields.index(index, offsetBy: 2)
            let comment = commentIndex < fields.endIndex
                ? fields[commentIndex...].joined(separator: " ")
                : "no comment"
            return "\(key.bits) \(key.sha256Fingerprint) "
                + "\(comment.isEmpty ? "no comment" : comment) (\(key.shortTypeName))"
        }
        return nil
    }
}
