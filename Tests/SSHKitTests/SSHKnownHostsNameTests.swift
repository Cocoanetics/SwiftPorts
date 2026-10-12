import Testing

@testable import SSHKit

@Suite("SSHKnownHostsName")
struct SSHKnownHostsNameTests {
    @Test func defaultPortIsBareHostname() {
        #expect(SSHKnownHostsName.make(host: "example.com", port: 22) == "example.com")
    }

    @Test func zeroPortIsBareHostname() {
        #expect(SSHKnownHostsName.make(host: "example.com", port: 0) == "example.com")
    }

    @Test func nondefaultPortIsBracketed() {
        #expect(SSHKnownHostsName.make(host: "example.com", port: 2222) == "[example.com]:2222")
    }
}
