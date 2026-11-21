import Foundation
import Crypto
import Testing
import ShellKit
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("Queue-backed LFS smudge")
    struct LFSSmudgeStreamTests {
        private let data = Data(repeating: 0x62, count: 200_000)

        private var pointer: Pointer {
            Pointer(oid: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                    size: Int64(data.count))
        }

        @Test("local objects stream in bounded chunks on the callback thread")
        func local() async throws {
            try await LFSStreamFixture.run { context, _, _ in
                _ = try await context.store.store(data, oid: pointer.oid)
                try checkLocal(context)
            }
        }

        private func checkLocal(_ context: LFSFilterContext) throws {
            let callbackThread = Thread.current
            var result = Data()
            var largest = 0
            let stream = LFSSmudgeStream(context: context, path: "a.lfs") {
                #expect(Thread.current === callbackThread)
                largest = max(largest, $0.count)
                result.append(contentsOf: $0)
            }
            try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
            #expect(result.isEmpty)
            try stream.close()
            #expect(result == data)
            #expect(largest <= 64 * 1024)
        }

        @Test("nonpointer and cutoff-sized pointer-looking input streams through", arguments: [0, 17, 1024, 400_000])
        func nonpointer(length: Int) async throws {
            try await LFSStreamFixture.run { context, _, _ in
                let input = length == 1024
                    ? Data(pointer.encoded.utf8) + Data(repeating: 0x20, count: 1024 - pointer.encoded.utf8.count)
                    : Data(repeating: 0x61, count: length)
                var result = Data()
                let stream = LFSSmudgeStream(context: context, path: "a.lfs") { result.append(contentsOf: $0) }
                for offset in stride(from: 0, to: input.count, by: 71) {
                    try input.subdata(in: offset..<min(offset + 71, input.count)).withUnsafeBytes(stream.write)
                }
                try stream.close()
                #expect(result == input)
            }
        }

        @Test("skip and fetch rejection never request a missing object", arguments: ["skip", "include", "exclude"])
        func skip(mode: String) async throws {
            let config = mode == "include" ? [("lfs.fetchinclude", "other/**")]
                : mode == "exclude" ? [("lfs.fetchexclude", "*.lfs")] : []
            LFSStreamURLProtocol.state.withLock { $0 = ({ _ in
                Issue.record("skip must not access the network")
                return LFSTransferReply(status: 500)
            }, []) }
            defer { LFSStreamURLProtocol.state.withLock { $0 = nil } }
            try await LFSStreamFixture.run(config: config, skip: mode == "skip") { context, _, _ in
                var result = Data()
                let stream = LFSSmudgeStream(context: context, path: "a.lfs") { result.append(contentsOf: $0) }
                try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
                try stream.close()
                #expect(result == Data(pointer.encoded.utf8))
                #expect(LFSStreamURLProtocol.state.withLock { $0?.1.isEmpty == true })
            }
        }

        @Test("missing and wrong-size local objects download through the queue", arguments: [false, true])
        func download(invalid: Bool) async throws {
            LFSStreamURLProtocol.state.withLock { $0 = ({ request in
                if request.url?.lastPathComponent == "batch" { return .batch(request) }
                return LFSTransferReply(body: data)
            }, []) }
            defer { LFSStreamURLProtocol.state.withLock { $0 = nil } }
            try await LFSStreamFixture.run { context, _, _ in
                if invalid {
                    let file = try await context.store.objectPath(pointer.oid)
                    try Data("bad".utf8).write(to: file)
                }
                var result = Data()
                let stream = LFSSmudgeStream(context: context, path: "a.lfs") { result.append(contentsOf: $0) }
                try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
                try stream.close()
                #expect(result == data)
                let requests = LFSStreamURLProtocol.state.withLock { $0?.1 ?? [] }
                #expect(requests.count == 2)
                let batch = try #require(requests.first?.httpBody)
                let json = try #require(JSONSerialization.jsonObject(with: batch) as? [String: Any])
                #expect((json["ref"] as? [String: String])?["name"] == "refs/heads/main")
                #expect(try Data(contentsOf: context.store.objectPathname(pointer.oid)) == data)
            }
        }

        @Test("no-action success is rechecked; suppression and optional fallback",
               arguments: ["required", "optional", "config", "env"])
        func noAction(mode: String) async throws {
            LFSStreamURLProtocol.state.withLock { $0 = ({ _ in
                let object = "{\"oid\":\"\(pointer.oid)\",\"size\":\(pointer.size)}"
                return LFSTransferReply(body: Data("{\"objects\":[\(object)]}".utf8))
            }, []) }
            defer { LFSStreamURLProtocol.state.withLock { $0 = nil } }
            try await LFSStreamFixture.run(config: mode == "config" ? [("lfs.skipdownloaderrors", "true")] : [],
                                           required: mode != "optional") { context, _, _ in
                if mode == "env" { Shell.current.environment["GIT_LFS_SKIP_DOWNLOAD_ERRORS"] = "true" }
                // Noncanonical input distinguishes optional-driver replay from suppression.
                let input = Data(pointer.encoded.replacingOccurrences(of: "\n", with: "\r\n").utf8)
                var result = Data()
                let stream = LFSSmudgeStream(context: context, path: "dir/a.lfs") { result.append(contentsOf: $0) }
                try input.withUnsafeBytes(stream.write)
                if mode == "required" {
                    do { try stream.close(); Issue.record("Missing downloaded object must fail") }
                    catch let error as LFSFilterFailure {
                        #expect(error.localizedDescription.hasPrefix(
                            "Error downloading object: dir/a.lfs (\(pointer.oid.prefix(7))): Smudge error: "))
                        #expect(error.underlying is CocoaError)
                    }
                    #expect(result.isEmpty)
                } else {
                    try stream.close()
                    #expect(result == (mode == "optional" ? input : Data(pointer.encoded.utf8)))
                }
            }
        }

        @Test("downstream errors propagate even when download errors are suppressed")
        func outputFailure() async throws {
            try await LFSStreamFixture.run(config: [("lfs.skipdownloaderrors", "true")], required: false) {
                context, _, _ in
                _ = try await context.store.store(data, oid: pointer.oid)
                var writes = 0
                let stream = LFSSmudgeStream(context: context, path: "a.lfs") { _ in
                    writes += 1
                    throw CocoaError(.fileWriteUnknown)
                }
                try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
                #expect(throws: CocoaError.self) { try stream.close() }
                #expect(writes == 1)
            }
        }

        @Test("selected remote retries precede fallback and a successful remote persists")
        func fallbackRemote() async throws {
            LFSStreamURLProtocol.state.withLock { $0 = ({ request in
                if request.url?.host == "chosen.example" {
                    return missingObject()
                }
                if request.url?.lastPathComponent == "batch" { return .batch(request) }
                return LFSTransferReply(body: data)
            }, []) }
            defer { LFSStreamURLProtocol.state.withLock { $0 = nil } }
            try await LFSStreamFixture.run(config: [
                ("remote.chosen.lfsurl", "https://chosen.example/lfs"),
                ("remote.backup.lfsurl", "https://backup.example/lfs"),
                ("branch.main.remote", "chosen"), ("lfs.remote.searchall", "true")
            ], endpoint: nil) { context, _, _ in
                for _ in 0..<2 {
                    var result = Data()
                    let stream = LFSSmudgeStream(context: context, path: "a.lfs") { result.append(contentsOf: $0) }
                    try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
                    try stream.close()
                    #expect(result == data)
                    try FileManager.default.removeItem(at: context.store.objectPathname(pointer.oid))
                }
                let hosts = LFSStreamURLProtocol.state.withLock {
                    $0?.1.filter { $0.url?.lastPathComponent == "batch" }.compactMap { $0.url?.host }
                }
                #expect(hosts == ["chosen.example", "chosen.example", "backup.example", "backup.example"])
            }
        }

        @Test("a no-action fallback ends the remote search but still checks the local object")
        func fallbackNoAction() async throws {
            LFSStreamURLProtocol.state.withLock { $0 = ({ request in
                if request.url?.host == "chosen.example" { return missingObject() }
                let object = "{\"oid\":\"\(pointer.oid)\",\"size\":\(pointer.size)}"
                return LFSTransferReply(body: Data("{\"objects\":[\(object)]}".utf8))
            }, []) }
            defer { LFSStreamURLProtocol.state.withLock { $0 = nil } }
            try await LFSStreamFixture.run(config: [
                ("remote.chosen.lfsurl", "https://chosen.example/lfs"),
                ("remote.empty.lfsurl", "https://empty.example/lfs"),
                ("remote.third.lfsurl", "https://third.example/lfs"),
                ("branch.main.remote", "chosen"), ("lfs.remote.searchall", "true")
            ], endpoint: nil) { context, _, _ in
                var result = Data()
                let stream = LFSSmudgeStream(context: context, path: "a.lfs") { result.append(contentsOf: $0) }
                try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
                #expect(throws: LFSFilterFailure.self) { try stream.close() }
                #expect(result.isEmpty)
                let hosts = LFSStreamURLProtocol.state.withLock { $0?.1.compactMap { $0.url?.host } }
                #expect(hosts == ["chosen.example", "chosen.example", "empty.example"])
            }
        }

        @Test("download diagnostics retain the queue's original cause")
        func diagnostic() async throws {
            LFSStreamURLProtocol.state.withLock { $0 = ({ _ in
                missingObject()
            }, []) }
            defer { LFSStreamURLProtocol.state.withLock { $0 = nil } }
            try await LFSStreamFixture.run { context, _, _ in
                let stream = LFSSmudgeStream(context: context, path: "a.lfs") { _ in
                    Issue.record("failed transform must not write output")
                }
                try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
                do { try stream.close(); Issue.record("download failure must propagate") }
                catch let error as LFSFilterFailure {
                    #expect(error.localizedDescription.contains("original transfer cause"))
                    #expect(error.underlying is LFSClientError)
                }
            }
        }

        private func missingObject() -> LFSTransferReply {
            let object = "{\"oid\":\"\(pointer.oid)\",\"size\":\(pointer.size),"
                + "\"error\":{\"code\":404,\"message\":\"original transfer cause\"}}"
            return LFSTransferReply(body: Data("{\"objects\":[\(object)]}".utf8))
        }

        @Test("denied object access performs no download")
        func authorization() async throws {
            LFSStreamURLProtocol.state.withLock { $0 = ({ _ in
                Issue.record("authorization denial must precede network access")
                return LFSTransferReply(status: 500)
            }, []) }
            defer { LFSStreamURLProtocol.state.withLock { $0 = nil } }
            try await LFSStreamFixture.run(refusing: { $0.pathComponents.contains("objects") }, {
                context, _, _ in
                let stream = LFSSmudgeStream(context: context, path: "a.lfs") { _ in
                    Issue.record("required failure must not write output")
                }
                try Data(pointer.encoded.utf8).withUnsafeBytes(stream.write)
                do { try stream.close(); Issue.record("sandbox denial must propagate") }
                catch let error as LFSFilterFailure { #expect(error.underlying is Sandbox.Denial) }
                #expect(LFSStreamURLProtocol.state.withLock { $0?.1.isEmpty == true })
            })
        }
    }
}
