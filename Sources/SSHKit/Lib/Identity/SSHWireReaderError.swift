enum SSHWireReaderError: Error {
    case truncated
    case invalidUTF8
}
