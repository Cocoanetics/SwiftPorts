import Foundation
import ShellKit
import SSHKit

extension SSHKeygenExecutable {
    static func verify(
        _ args: SSHKeygenArguments, mode: String, stdin: InputSource, stdout: OutputSink, stderr: OutputSink
    ) async throws -> Int32 {
        var time = Date()
        for option in args.options {
            guard option.lowercased().hasPrefix("verify-time=") else {
                throw SSHKeygenError("Invalid option \"\(option)\"")
            }
            do { time = try SSHKeygenTime.parse(String(option.dropFirst(12))) }
            catch { throw SSHKeygenError("Invalid \"verify-time\" option") }
        }
        let text = String(decoding: try await read(args["s"] ?? ""), as: UTF8.self)
        if mode == "find-principals" {
            let key = try SSHSignature.signingKey(in: text)
            let path = args["f"] ?? ""
            let allowed = try await AllowedSigners(String(decoding: read(path), as: UTF8.self), path: path)
            let principals = allowed.principals(for: key, at: time, diagnostic: { stderr.write($0 + "\n") })
            if principals.isEmpty { stderr.write("No principal matched.\n"); return 255 }
            stdout.write(principals.joined(separator: "\n") + "\n")
            return 0
        }
        let signature = try SSHSignature(armored: text)
        try signature.verify(message: await stdin.readAllData(), namespace: args["n"] ?? "")
        if let revoked = args["r"], mode == "verify" {
            try await SSHRevocationList.check(signature.publicKey, data: read(revoked))
        }
        if mode != "check-novalidate" {
            let path = args["f"] ?? ""
            let allowed = try await AllowedSigners(String(decoding: read(path), as: UTF8.self), path: path)
            let principals = allowed.principals(
                for: signature.publicKey, principal: args["I"], namespace: args["n"], at: time,
                diagnostic: { stderr.write($0 + "\n") })
            if principals.isEmpty {
                if !args.flags.contains("q") { stdout.write("Could not verify signature.\n") }
                return 255
            }
        }
        if !args.flags.contains("q") {
            let principal = args["I"].map { " for \($0)" } ?? ""
            stdout.write("Good \"\(args["n"] ?? "")\" signature\(principal) with "
                + "\(signature.publicKey.shortTypeName) key \(signature.publicKey.sha256Fingerprint)\n")
        }
        return 0
    }
}
