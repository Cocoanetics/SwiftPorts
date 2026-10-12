enum SSHClientChannelError: Error {
    case unexpectedChannelType
    case authenticationExhausted
    case authenticationCompleted
    case connectionClosed
    case connectionClosedBeforeHostKeyVerification
}
