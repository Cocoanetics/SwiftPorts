public enum SSHClientChannelError: Error {
    case unexpectedChannelType
    case authenticationExhausted
    case authenticationCompleted
    case connectionClosed
    case connectionClosedBeforeHostKeyVerification

    /// The peer replied `SSH_MSG_CHANNEL_FAILURE` to a `pty-req`. Mirrors `client_status_confirm`'s
    /// `CONFIRM_TTY` handling (`clientloop.c`): the caller decides whether that's fatal (`-t`
    /// explicitly forced a PTY) or just means falling back to a PTY-less session (the PTY was
    /// only requested automatically, e.g. a command-less login shell). `public` so `SSHCommand`
    /// (a separate module) can catch this specific case.
    case pseudoTerminalRequestFailed
}
