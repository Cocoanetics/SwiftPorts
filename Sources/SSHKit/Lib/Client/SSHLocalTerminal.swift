import NIOSSH
import ShellKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

/// Captures the local controlling terminal's `TERM`, window size, and termios mode flags for a
/// `pty-req` (RFC 4254 §6.2) — the client-side counterpart of `client_session2_setup`'s pty-req
/// construction (`clientloop.c`) and `ssh_tty_make_modes` (`ttymodes.c`).
#if !os(Windows)
public enum SSHLocalTerminal {
    /// Builds a `pty-req` from the local terminal on fd 0. Always succeeds — a window size or
    /// termios read failure degrades to zeroed/empty fields exactly like `client_session2_setup`
    /// itself (`ioctl(in_fd, TIOCGWINSZ, &ws)` failing leaves `ws` zeroed; `ssh_tty_make_modes`
    /// with no usable `tio` just emits an empty mode list), rather than refusing to request a PTY.
    /// `wantReply` is `true`, matching OpenSSH's own `channel_request_start(..., "pty-req", 1)`.
    public static func pseudoTerminalRequest() -> SSHChannelRequestEvent.PseudoTerminalRequest {
        let term = Shell.env("TERM") ?? ""

        var size = winsize()
        let haveSize = ioctl(0, Self.winsizeRequest, &size) == 0

        var tio = termios()
        let modes = tcgetattr(0, &tio) == 0 ? Self.terminalModes(from: tio) : SSHTerminalModes([:])

        return SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: haveSize ? Int(size.ws_col) : 0,
            terminalRowHeight: haveSize ? Int(size.ws_row) : 0,
            terminalPixelWidth: haveSize ? Int(size.ws_xpixel) : 0,
            terminalPixelHeight: haveSize ? Int(size.ws_ypixel) : 0,
            terminalModes: modes)
    }

    /// The local window size, for a `window-change` sent in response to `SIGWINCH`
    /// (`client_check_window_change`, `clientloop.c`). `nil` when fd 0 has no window size to read
    /// (not a terminal).
    public static func windowSize() -> (columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)? {
        var size = winsize()
        guard ioctl(0, Self.winsizeRequest, &size) == 0 else {
            return nil
        }
        return (Int(size.ws_col), Int(size.ws_row), Int(size.ws_xpixel), Int(size.ws_ypixel))
    }

    #if os(Linux) || os(Android)
    private static let winsizeRequest = UInt(TIOCGWINSZ)
    #else
    private static let winsizeRequest = TIOCGWINSZ
    #endif

    /// `enter_raw_mode()` (`sshtty.c`): disables input/output processing and local echo on fd 0
    /// so every keystroke reaches the remote PTY unmangled. Returns the prior termios state to
    /// restore via `leaveRawMode(_:)`, or `nil` if fd 0 isn't a terminal `tcgetattr` can read —
    /// this port threads that saved state through the caller rather than `sshtty.c`'s hidden
    /// `_saved_tio` static, since there's no single global session here.
    public static func enterRawMode() -> termios? {
        var tio = termios()
        guard tcgetattr(0, &tio) == 0 else {
            return nil
        }
        let saved = tio

        tio.c_iflag |= UInt(IGNPAR)
        tio.c_iflag &= ~UInt(ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF)
        tio.c_lflag &= ~UInt(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL)
        tio.c_lflag &= ~UInt(IEXTEN)
        tio.c_oflag &= ~UInt(OPOST)
        withUnsafeMutableBytes(of: &tio.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }

        guard tcsetattr(0, TCSADRAIN, &tio) == 0 else {
            return nil
        }
        return saved
    }

    /// `leave_raw_mode()` (`sshtty.c`): restores the termios state `enterRawMode()` returned.
    public static func leaveRawMode(_ saved: termios) {
        var saved = saved
        tcsetattr(0, TCSADRAIN, &saved)
    }

    /// `ssh_tty_make_modes` (`ttymodes.c`), driven by the same `TTYCHAR`/`TTYMODE` table
    /// (`ttymodes.h`) — the portable cross-platform subset of it: legacy BSD-only characters
    /// (`VDSUSP`, `VSTATUS`, …) and flags (`IUCLC`, `XCASE`, `OLCUC`, …) that don't exist in
    /// Linux's `termios.h` are left out, the same way `ttymodes.h`'s own `#ifdef`s drop them on
    /// platforms that lack them.
    private static func terminalModes(from original: termios) -> SSHTerminalModes {
        var tio = original
        var mapping: [SSHTerminalModes.Opcode: SSHTerminalModes.OpcodeValue] = [:]

        mapping[.TTY_OP_ISPEED] = SSHTerminalModes.OpcodeValue(rawValue: UInt32(Self.baudRate(cfgetispeed(&tio))))
        mapping[.TTY_OP_OSPEED] = SSHTerminalModes.OpcodeValue(rawValue: UInt32(Self.baudRate(cfgetospeed(&tio))))

        func flag(_ value: UInt32) -> SSHTerminalModes.OpcodeValue {
            SSHTerminalModes.OpcodeValue(rawValue: value)
        }
        // `termios.c_cc` is a fixed-size C tuple, not a Swift array — index into its raw bytes by
        // the platform's `V*` constant rather than hand-writing the tuple's field order (which
        // also differs between Darwin and Linux). `special_char_encode()` (`ttymodes.c`):
        // `_POSIX_VDISABLE` becomes the wire value 255.
        func char(_ index: Int32) -> SSHTerminalModes.OpcodeValue {
            let value = withUnsafeBytes(of: tio.c_cc) { $0[Int(index)] }
            // `_POSIX_VDISABLE` is `(unsigned char)'\377'` (0xff) on every POSIX platform
            // (`<sys/_types/_posix_vdisable.h>`, `bits/termios-c_cc.h`) — the macro itself isn't
            // usable from Swift here (the Darwin SDK marks it unavailable), so the literal stands
            // in for it, matching `special_char_encode()` (`ttymodes.c`).
            return SSHTerminalModes.OpcodeValue(rawValue: value == 0xff ? 255 : UInt32(value))
        }

        mapping[.VINTR] = char(VINTR)
        mapping[.VQUIT] = char(VQUIT)
        mapping[.VERASE] = char(VERASE)
        mapping[.VKILL] = char(VKILL)
        mapping[.VEOF] = char(VEOF)
        mapping[.VEOL] = char(VEOL)
        mapping[.VEOL2] = char(VEOL2)
        mapping[.VSTART] = char(VSTART)
        mapping[.VSTOP] = char(VSTOP)
        mapping[.VSUSP] = char(VSUSP)
        mapping[.VREPRINT] = char(VREPRINT)
        mapping[.VWERASE] = char(VWERASE)
        mapping[.VLNEXT] = char(VLNEXT)
        mapping[.VDISCARD] = char(VDISCARD)

        mapping[.IGNPAR] = flag(tio.c_iflag & UInt(IGNPAR) != 0 ? 1 : 0)
        mapping[.PARMRK] = flag(tio.c_iflag & UInt(PARMRK) != 0 ? 1 : 0)
        mapping[.INPCK] = flag(tio.c_iflag & UInt(INPCK) != 0 ? 1 : 0)
        mapping[.ISTRIP] = flag(tio.c_iflag & UInt(ISTRIP) != 0 ? 1 : 0)
        mapping[.INLCR] = flag(tio.c_iflag & UInt(INLCR) != 0 ? 1 : 0)
        mapping[.IGNCR] = flag(tio.c_iflag & UInt(IGNCR) != 0 ? 1 : 0)
        mapping[.ICRNL] = flag(tio.c_iflag & UInt(ICRNL) != 0 ? 1 : 0)
        mapping[.IXON] = flag(tio.c_iflag & UInt(IXON) != 0 ? 1 : 0)
        mapping[.IXANY] = flag(tio.c_iflag & UInt(IXANY) != 0 ? 1 : 0)
        mapping[.IXOFF] = flag(tio.c_iflag & UInt(IXOFF) != 0 ? 1 : 0)
        mapping[.IMAXBEL] = flag(tio.c_iflag & UInt(IMAXBEL) != 0 ? 1 : 0)

        mapping[.ISIG] = flag(tio.c_lflag & UInt(ISIG) != 0 ? 1 : 0)
        mapping[.ICANON] = flag(tio.c_lflag & UInt(ICANON) != 0 ? 1 : 0)
        mapping[.ECHO] = flag(tio.c_lflag & UInt(ECHO) != 0 ? 1 : 0)
        mapping[.ECHOE] = flag(tio.c_lflag & UInt(ECHOE) != 0 ? 1 : 0)
        mapping[.ECHOK] = flag(tio.c_lflag & UInt(ECHOK) != 0 ? 1 : 0)
        mapping[.ECHONL] = flag(tio.c_lflag & UInt(ECHONL) != 0 ? 1 : 0)
        mapping[.NOFLSH] = flag(tio.c_lflag & UInt(NOFLSH) != 0 ? 1 : 0)
        mapping[.TOSTOP] = flag(tio.c_lflag & UInt(TOSTOP) != 0 ? 1 : 0)
        mapping[.IEXTEN] = flag(tio.c_lflag & UInt(IEXTEN) != 0 ? 1 : 0)
        mapping[.ECHOCTL] = flag(tio.c_lflag & UInt(ECHOCTL) != 0 ? 1 : 0)
        mapping[.ECHOKE] = flag(tio.c_lflag & UInt(ECHOKE) != 0 ? 1 : 0)
        mapping[.PENDIN] = flag(tio.c_lflag & UInt(PENDIN) != 0 ? 1 : 0)

        mapping[.OPOST] = flag(tio.c_oflag & UInt(OPOST) != 0 ? 1 : 0)
        mapping[.ONLCR] = flag(tio.c_oflag & UInt(ONLCR) != 0 ? 1 : 0)
        mapping[.OCRNL] = flag(tio.c_oflag & UInt(OCRNL) != 0 ? 1 : 0)
        mapping[.ONOCR] = flag(tio.c_oflag & UInt(ONOCR) != 0 ? 1 : 0)
        mapping[.ONLRET] = flag(tio.c_oflag & UInt(ONLRET) != 0 ? 1 : 0)

        mapping[.CS7] = flag(tio.c_cflag & UInt(CS7) != 0 ? 1 : 0)
        mapping[.CS8] = flag(tio.c_cflag & UInt(CS8) != 0 ? 1 : 0)
        mapping[.PARENB] = flag(tio.c_cflag & UInt(PARENB) != 0 ? 1 : 0)
        mapping[.PARODD] = flag(tio.c_cflag & UInt(PARODD) != 0 ? 1 : 0)

        return SSHTerminalModes(mapping)
    }

    /// `speed_to_baud()` (`ttymodes.c`) — the portable subset of POSIX `speed_t` constants shared
    /// by Darwin and Linux; an unrecognized speed falls back to 9600, matching the C `default:`.
    private static func baudRate(_ speed: speed_t) -> Int32 {
        switch speed {
        case speed_t(B0): return 0
        case speed_t(B50): return 50
        case speed_t(B75): return 75
        case speed_t(B110): return 110
        case speed_t(B134): return 134
        case speed_t(B150): return 150
        case speed_t(B200): return 200
        case speed_t(B300): return 300
        case speed_t(B600): return 600
        case speed_t(B1200): return 1_200
        case speed_t(B1800): return 1_800
        case speed_t(B2400): return 2_400
        case speed_t(B4800): return 4_800
        case speed_t(B9600): return 9_600
        case speed_t(B19200): return 19_200
        case speed_t(B38400): return 38_400
        case speed_t(B57600): return 57_600
        case speed_t(B115200): return 115_200
        case speed_t(B230400): return 230_400
        default: return 9_600
        }
    }
}
#endif
