import Foundation
import Testing
@testable import GitLFSKit

@Suite("Pointer")
struct PointerTests {

    static let oid = PointerRejection.oid
    static let canonical = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(oid)
        size 12345

        """

    @Test("encodes the v1 pointer byte for byte")
    func encodes() {
        #expect(Pointer(oid: Self.oid, size: 12345).encoded == Self.canonical)
    }

    @Test("decodes a canonical pointer and encodes it back")
    func roundTrips() throws {
        let pointer = try Pointer.decode(Data(Self.canonical.utf8))
        #expect(pointer.oid == Self.oid)
        #expect(pointer.size == 12345)
        #expect(pointer.oidType == "sha256")
        #expect(pointer.version == Pointer.latestVersion)
        #expect(pointer.extensions.isEmpty)
        #expect(pointer.canonical)
        #expect(pointer.encoded == Self.canonical)
    }

    @Test("the empty file is the empty pointer, which encodes to nothing")
    func emptyFile() throws {
        let pointer = try Pointer.decode(Data())
        #expect(pointer == .empty)
        #expect(pointer.oid == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(pointer.size == 0)
        #expect(pointer.canonical)
        #expect(pointer.encoded == "")
    }

    @Test("surrounding white space and CRLF line ends decode, but aren't canonical")
    func nonCanonical() throws {
        let crlf = Self.canonical.replacingOccurrences(of: "\n", with: "\r\n")
        for text in ["\n\n" + Self.canonical + "  \n", crlf] {
            let pointer = try Pointer.decode(Data(text.utf8))
            #expect(try pointer == Pointer.decode(Data(Self.canonical.utf8)).withCanonical(false))
        }
    }

    @Test("the pre-release hawser version is an alias of v1")
    func hawserAlias() throws {
        let text = Self.canonical.replacingOccurrences(
            of: "https://git-lfs.github.com/spec/v1", with: "https://hawser.github.com/spec/v1")
        let pointer = try Pointer.decode(Data(text.utf8))
        #expect(pointer.oid == Self.oid)
        #expect(!pointer.canonical)
        #expect(pointer.encoded == Self.canonical)
    }

    @Test("extensions are kept, ordered by priority, and re-emitted in that order")
    func extensionOrdering() throws {
        let a = PointerRejection.otherOID
        let b = "a3f9cc7a3e6e2c4c8d4e8f1a1b5d0b9c7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b"
        let text = """
            version https://git-lfs.github.com/spec/v1
            ext-1-bar sha256:\(b)
            ext-0-foo sha256:\(a)
            oid sha256:\(Self.oid)
            size 12345

            """
        let pointer = try Pointer.decode(Data(text.utf8))
        #expect(pointer.extensions == [
            PointerExtension(name: "foo", priority: 0, oid: a),
            PointerExtension(name: "bar", priority: 1, oid: b),
        ])
        #expect(!pointer.canonical)
        let ordered = """
            version https://git-lfs.github.com/spec/v1
            ext-0-foo sha256:\(a)
            ext-1-bar sha256:\(b)
            oid sha256:\(Self.oid)
            size 12345

            """
        #expect(pointer.encoded == ordered)
        #expect(try Pointer.decode(Data(ordered.utf8)).canonical)
    }

    @Test("rejects what git-lfs rejects, with its words", arguments: PointerRejection.all)
    func rejects(_ rejection: PointerRejection) {
        #expect {
            try Pointer.decode(Data(rejection.text.utf8))
        } throws: { error in
            String(describing: error) == rejection.error
        }
    }

    @Test("a pointer file must be under 1024 bytes")
    func sizeCutoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pointer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let under = directory.appendingPathComponent("1023")
        try Data(Self.padded(to: 1023).utf8).write(to: under)
        let pointer = try await Pointer.decode(fileAt: under)
        #expect(pointer.canonical)
        #expect(pointer.extensions.count == 1)

        let at = directory.appendingPathComponent("1024")
        try Data(Self.padded(to: 1024).utf8).write(to: at)
        await #expect {
            try await Pointer.decode(fileAt: at)
        } throws: { error in
            String(describing: error) == "Pointer file error: file size exceeds Git LFS pointer size cutoff"
        }
    }

    @Test("data is only read up to the 1024-byte cutoff")
    func dataCutoff() throws {
        #expect(try Pointer.decode(Data(Self.padded(to: 1024).utf8)).canonical)
        // The 1025th byte, the final newline, is never seen.
        let pointer = try Pointer.decode(Data(Self.padded(to: 1025).utf8))
        #expect(pointer.size == 12345)
        #expect(!pointer.canonical)
    }

    /// A canonical pointer exactly `length` bytes long: an extension whose
    /// name takes up the slack.
    static func padded(to length: Int) -> String {
        func text(_ name: String, size: Int) -> String {
            """
            version https://git-lfs.github.com/spec/v1
            ext-0-\(name) sha256:\(PointerRejection.otherOID)
            oid sha256:\(oid)
            size \(size)

            """
        }
        let base = text("", size: 12345).utf8.count
        return text(String(repeating: "n", count: length - base), size: 12345)
    }
}
