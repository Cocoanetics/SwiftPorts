import Foundation
import ShellKit
import SSHKit

extension SSHKeygenExecutable {
    static func publicKey(
        _ args: SSHKeygenArguments, stdout: OutputSink, prompt: @escaping PassphrasePrompt
    ) async throws -> Int32 {
        let path = args["f"] ?? ""
        let data = try await read(path)
        let key: SSHPublicKey
        let comment: String
        if args.flags.contains("l"),
           let publicKey = try? SSHPublicKey(openSSHLine: String(decoding: data, as: UTF8.self)) {
            key = publicKey
            let parts = String(decoding: data, as: UTF8.self).split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            comment = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .newlines) : "no comment"
        } else if args.flags.contains("l"),
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
            let privateKey = try await IdentityLoader.loadKey(path: path, passphrasePrompt: { _ in
                await prompt("Enter passphrase for \"\(path)\": ")
            })
            key = privateKey.publicKey
            comment = privateKey.comment
        }
        if args.flags.contains("l") {
            stdout.write("\(key.bits) \(key.sha256Fingerprint) "
                + "\(comment.isEmpty ? "no comment" : comment) (\(key.shortTypeName))\n")
        } else { stdout.write(key.openSSHLine(comment: comment) + "\n") }
        return 0
    }
}
