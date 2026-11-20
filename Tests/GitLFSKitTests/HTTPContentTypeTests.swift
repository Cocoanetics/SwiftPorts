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
}
