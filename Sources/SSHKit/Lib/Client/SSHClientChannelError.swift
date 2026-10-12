enum SSHClientChannelError: Error {
    case unexpectedChannelType
    case authenticationExhausted
    case connectionClosedBeforeHostKeyVerification
}
