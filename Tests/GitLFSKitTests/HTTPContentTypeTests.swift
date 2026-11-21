import Foundation
import Testing
@testable import GitLFSKit

struct HTTPContentTypeTests {
    static let samples: [(Data, String)] = [
        (Data(), "text/plain; charset=utf-8"),
        (Data(" \n<html>".utf8), "text/html; charset=utf-8"),
        (Data("<htmlx>".utf8), "text/plain; charset=utf-8"),
        (Data(" <?xml version='1.0'".utf8), "text/xml; charset=utf-8"),
        (Data("%PDF-1.7".utf8), "application/pdf"),
        (Data([137, 80, 78, 71, 13, 10, 26, 10]), "image/png"),
        (Data([255, 216, 255]), "image/jpeg"),
        (Data(".snd".utf8), "audio/basic"),
        (Data("RIFF1234WEBPVP".utf8), "image/webp"),
        (Data([0, 0, 0, 20]) + Data("ftypmp42\0\0\0\0mp41".utf8), "video/mp4"),
        (Data("wOFF".utf8), "font/woff"),
        (Data([0, 97, 115, 109]), "application/wasm"),
        (Data([255, 254, 0, 0]), "text/plain; charset=utf-16le"),
        (Data([255]), "text/plain; charset=utf-8"),
        (Data([128, 1]), "application/octet-stream"),
        (Data(repeating: 32, count: 512) + Data([0]), "text/plain; charset=utf-8")
    ]

    @Test("Go DetectContentType signatures and fallbacks", arguments: samples)
    func sniff(sample: (Data, String)) {
        #expect(HTTPContentType.detect(sample.0) == sample.1)
    }

    @Test("upload preflight preserves the 512-byte sniff and disabled detection", arguments: samples)
    func uploadPreflight(sample: (Data, String)) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try sample.0.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let object = LFSBatchObject(oid: String(repeating: "a", count: 64), size: Int64(sample.0.count))
        #expect(try LFSTransferQueue.uploadContentType(file, object: object, detect: true) == sample.1)
        #expect(try LFSTransferQueue.uploadContentType(file, object: object, detect: false)
            == "application/octet-stream")
        let corrupt = LFSBatchObject(oid: object.oid, size: object.size + 1, name: "a.dat")
        do {
            _ = try LFSTransferQueue.uploadContentType(file, object: corrupt, detect: false)
            Issue.record("Disabling Content-Type detection must not bypass size validation")
        } catch let error as LFSTransferError {
            #expect(!error.retry)
            #expect(error.message == "corrupt object: a.dat (\(object.oid))")
        }
    }
}
