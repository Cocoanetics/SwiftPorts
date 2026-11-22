import Foundation
import ForgeKit
import GitKit
import ShellKit

/// GitKit's signing hook done as git's `sign_buffer` does it
/// (`gpg-interface.c`), through the shell: the program runs through the
/// shell's `ProcessLauncher` and its files go through the shell's
/// sandbox, so signing works where `Foundation.Process` doesn't and a
/// sandbox that refuses the program refuses the signature.
///
/// ``GitClient`` installs one on every `Repository` it opens, and turns
/// GitKit's own external-program fallback off, so nothing signs around
/// the shell.
///
/// GitKit calls it synchronously on the thread running the operation,
/// inside `Libgit2Sandboxing`'s lock (and, for an amend, with
/// `index.lock` held); the launch is bridged to the shell's async world
/// with ``ForgeKit/BlockingBridge``, never by awaiting on that thread.
struct ShellSigner: GitSigner {
    let client: GitClient
    let shell: Shell
    var cancellation: BlockingBridgeCancellation?

    func sign(_ payload: [UInt8], request: SigningRequest) throws -> String {
        // Read here rather than taken from `request`: GitKit hands an
        // explicit `SignMode` an OpenPGP hint and no settings, while git
        // takes the format, program and default key from config whatever
        // asked for the signature.
        let settings = try GitClient.SigningSettings(in: client.workingDirectory)
        let key = request.key.flatMap { $0.isEmpty ? nil : $0 } ?? settings.signingKey
        return try BlockingBridge.runBlocking(cancellation: cancellation) { [client, shell] in
            try await shell.withCurrent {
                try await client.signBuffer(payload, key: key, identity: request.identity, settings: settings)
            }
        }
    }
}
