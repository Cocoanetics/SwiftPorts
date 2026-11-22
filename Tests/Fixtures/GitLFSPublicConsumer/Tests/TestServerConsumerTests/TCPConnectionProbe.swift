import Foundation
import Testing
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Tests TCP establishment without sending or waiting for an HTTP response.
enum TCPConnectionProbe {
    /// False means explicit connection refusal. Timeouts and all other errors fail the test.
    static func connects(port: Int) throws -> Bool {
        #if os(Windows)
        var startup = WSADATA()
        try #require(WSAStartup(WORD(0x0202), &startup) == 0)
        defer { WSACleanup() }
        let descriptor = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
        try #require(descriptor != INVALID_SOCKET)
        defer { closesocket(descriptor) }
        var mode: u_long = 1
        try #require(ioctlsocket(descriptor, FIONBIO, &mode) == 0)
        let refused = WSAECONNREFUSED
        #else
        #if os(Linux)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        try #require(flags >= 0)
        try #require(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        let refused = ECONNREFUSED
        #endif

        var address = sockaddr_in()
        address.sin_family = numericCast(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        #if os(Windows)
        address.sin_addr.S_un.S_addr = UInt32(0x7f000001).bigEndian
        #else
        address.sin_addr.s_addr = UInt32(0x7f000001).bigEndian
        #endif
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.connect(descriptor, $0, Int32(MemoryLayout<sockaddr_in>.size))
                #else
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        if connected == 0 { return true }
        #if os(Windows)
        let initialError = WSAGetLastError()
        if initialError == refused { return false }
        try #require(initialError == WSAEWOULDBLOCK, "Unexpected TCP connect error: \(initialError)")

        // Winsock select reports failed connects in exceptfds and successes in writefds.
        var writable = fd_set()
        writable.fd_count = 1
        writable.fd_array.0 = descriptor
        var exceptional = writable
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let ready = WinSDK.select(0, nil, &writable, &exceptional, &timeout)
        #else
        let initialError = errno
        if initialError == refused { return false }
        try #require(initialError == EINPROGRESS, "Unexpected TCP connect error: \(initialError)")
        var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pending, 1, 5_000)
        #endif
        // Neither a timeout nor a socket/poll failure is evidence of a closed listener.
        try #require(ready > 0, "TCP connection attempt timed out or failed: \(ready)")

        var connectionError: Int32 = 0
        #if os(Windows)
        var length = Int32(MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &connectionError) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<Int32>.size) {
                WinSDK.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, $0, &length)
            }
        }
        #else
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectionError, &length)
        #endif
        try #require(result == 0)
        try #require(connectionError == 0 || connectionError == refused,
                     "Unexpected TCP connection error: \(connectionError)")
        return connectionError == 0
    }
}
