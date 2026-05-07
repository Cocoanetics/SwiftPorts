import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // HTTPURLResponse is in this module on Linux
#endif
import HTTPTypes
import Testing
@testable import GitHub

extension HTTPMockedNetworkTests {
    @Suite struct OAuthDeviceFlowTests {

        @Test func decodesDeviceCodeResponse() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let body = Data(#"""
                    {"device_code":"abc123","user_code":"WDJB-MJHT","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
                    """#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let flow = OAuthDeviceFlow(clientID: "test-client", session: session)
            let code = try await flow.requestDeviceCode(scopes: ["repo", "read:org"])
            #expect(code.deviceCode == "abc123")
            #expect(code.userCode == "WDJB-MJHT")
            #expect(code.verificationUri.absoluteString == "https://github.com/login/device")
            #expect(code.expiresIn == 900)
            #expect(code.interval == 5)
        }

        @Test func returnsAccessTokenOnSuccess() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let body = Data(#"""
                    {"access_token":"gho_abc","token_type":"bearer","scope":"repo,read:org"}
                    """#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let flow = OAuthDeviceFlow(clientID: "test-client", session: session)
            let token = try await flow.exchangeOnce(deviceCode: "abc123")
            #expect(token.accessToken == "gho_abc")
            #expect(token.tokenType == "bearer")
            #expect(token.scope == "repo,read:org")
        }

        @Test func mapsAuthorizationPending() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let body = Data(#"""
                    {"error":"authorization_pending","error_description":"The authorization request is still pending."}
                    """#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let flow = OAuthDeviceFlow(clientID: "test-client", session: session)
            await #expect(throws: OAuthDeviceFlowError.self) {
                _ = try await flow.exchangeOnce(deviceCode: "abc123")
            }
        }

        @Test func mapsAccessDenied() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let body = Data(#"""
                    {"error":"access_denied","error_description":"The user denied the request."}
                    """#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let flow = OAuthDeviceFlow(clientID: "test-client", session: session)
            do {
                _ = try await flow.exchangeOnce(deviceCode: "abc123")
                Issue.record("expected throw")
            } catch OAuthDeviceFlowError.accessDenied {
                // expected
            } catch {
                Issue.record("wrong error type: \(error)")
            }
        }

        @Test func pollEventuallySucceeds() async throws {
            let session = MockURLProtocol.session()
            let attempts = TestLockedBox<Int>(0)
            MockURLProtocol.handler = { request in
                let n = attempts.withLock { v -> Int in v += 1; return v }
                let json: String
                if n < 3 {
                    json = #"{"error":"authorization_pending"}"#
                } else {
                    json = #"{"access_token":"gho_xyz","token_type":"bearer","scope":"repo"}"#
                }
                let body = Data(json.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let flow = OAuthDeviceFlow(clientID: "test", session: session)
            // Synthesize a device code with interval=0 so the poll loop
            // doesn't block the test for 5+ seconds per attempt.
            let code = DeviceCode(
                deviceCode: "abc", userCode: "WDJB-MJHT",
                verificationUri: URL(string: "https://github.com/login/device")!,
                expiresIn: 60, interval: 0)
            let token = try await flow.pollForToken(deviceCode: code)
            #expect(token.accessToken == "gho_xyz")
            #expect(attempts.withLock { $0 } == 3)
        }
    }
}
