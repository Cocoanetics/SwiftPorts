import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Prompts for an encrypted identity file's passphrase the way `ssh(1)`'s `read_passphrase()`
/// does for `load_identity_file` (`sshconnect2.c` line 1548): the exact wording
/// `"Enter passphrase for key '%.100s': "`, read from `/dev/tty` with echo disabled — not stdin,
/// so a redirected/piped stdin (the common non-interactive case for this port's callers) neither
/// sees the prompt text nor has its data mistaken for a passphrase.
///
/// `read_passphrase(prompt, 0)` (the flags `load_identity_file` passes) falls back to
/// `SSH_ASKPASS` only when no controlling terminal is available at all; a GUI askpass helper is
/// out of scope here (issue #115), so a missing `/dev/tty` is simply treated the same as the user
/// declining — matching `read_passphrase`'s own behavior when no askpass is configured either.
public enum SSHPassphrasePrompt {
    #if os(Windows)
    public static func readFromTTY(path: String) async -> String? {
        nil
    }
    #else
    public static func readFromTTY(path: String) async -> String? {
        guard let tty = fopen("/dev/tty", "r+") else {
            return nil
        }
        defer { fclose(tty) }
        let fd = fileno(tty)

        var original = termios()
        guard tcgetattr(fd, &original) == 0 else {
            return nil
        }
        var silenced = original
        silenced.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(fd, TCSANOW, &silenced)
        defer { tcsetattr(fd, TCSANOW, &original) }

        let prompt = "Enter passphrase for key '\(path.prefix(100))': "
        fputs(prompt, tty)
        fflush(tty)

        var buffer = [UInt8](repeating: 0, count: 1024)
        let line = buffer.withUnsafeMutableBytes { raw -> String? in
            // `raw.baseAddress` is never `nil` here — `buffer` is a fixed non-empty allocation —
            // but some platforms (Android's Bionic `libc`) import `fgets`'s first parameter as
            // non-optional, so the pointer must be force-unwrapped rather than passed through
            // `?.` chaining.
            guard fgets(raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), tty) != nil else {
                return nil
            }
            let length = raw.prefix(while: { $0 != 0 }).count
            return String(decoding: raw.prefix(length), as: UTF8.self)
        }
        fputs("\n", tty)
        fflush(tty)

        guard var passphrase = line else {
            return nil
        }
        if passphrase.hasSuffix("\n") {
            passphrase.removeLast()
        }
        return passphrase
    }
    #endif
}
