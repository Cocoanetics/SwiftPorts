import Foundation

/// Bytes git-lfs refuses as a pointer, and what it says about them
/// (checked against `git lfs pointer --pointer=<file>` by the oracle suite).
struct PointerRejection: Sendable, CustomStringConvertible {
    let name: String
    let text: String
    let error: String

    var description: String { name }

    static let oid = "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"
    static let otherOID = "6c17f2007cbe934aee6e309b28b2dba3c119c5dff2ef813ed124699efe319868"
    static let version = "version https://git-lfs.github.com/spec/v1\n"

    static let all: [PointerRejection] = [
        .init(name: "no LFS header", text: "hello world\n",
              error: "Pointer file error: invalid header"),
        .init(name: "line without a value", text: "git-lfs\n",
              error: "Pointer file error: error reading line 0: git-lfs"),
        .init(name: "unknown key", text: version + "foo bar\noid sha256:\(oid)\nsize 12345\n",
              error: "pointer parsing: Expected key oid, got foo"),
        .init(name: "keys out of order", text: version + "size 12345\noid sha256:\(oid)\n",
              error: "pointer parsing: Expected key oid, got size"),
        .init(name: "oid before version", text: "oid sha256:\(oid)\n" + version + "size 12345\n",
              error: "Pointer file error: pointer parsing: Expected key version, got oid"),
        .init(name: "duplicate version", text: version + version + "oid sha256:\(oid)\nsize 12345\n",
              error: "pointer parsing: Expected key oid, got version"),
        .init(name: "duplicate oid", text: version + "oid sha256:\(oid)\noid sha256:\(oid)\nsize 12345\n",
              error: "pointer parsing: Expected key size, got oid"),
        .init(name: "line after size", text: version + "oid sha256:\(oid)\nsize 12345\nsize 12345\n",
              error: "Pointer file error: extra line: size 12345"),
        .init(name: "empty version", text: "version \next-0-x-git-lfs sha256:\(otherOID)\noid sha256:\(oid)\nsize 12345\n",
              error: "Pointer file error: Missing version"),
        .init(name: "unknown version", text: "version https://git-lfs.github.com/spec/v2\noid sha256:\(oid)\nsize 1\n",
              error: "Invalid version: https://git-lfs.github.com/spec/v2"),
        .init(name: "no oid", text: version,
              error: "Invalid OID"),
        .init(name: "oid without type", text: version + "oid \(oid)\nsize 12345\n",
              error: "Invalid OID value: \(oid)"),
        .init(name: "oid of another type", text: version + "oid md5:\(oid)\nsize 12345\n",
              error: "Invalid OID type: md5"),
        .init(name: "uppercase oid", text: version + "oid sha256:\(oid.uppercased())\nsize 12345\n",
              error: "Invalid OID: \(oid.uppercased())"),
        .init(name: "short oid", text: version + "oid sha256:abc123\nsize 12345\n",
              error: "Invalid OID: abc123"),
        .init(name: "negative size", text: version + "oid sha256:\(oid)\nsize -1\n",
              error: "invalid size: \"-1\""),
        .init(name: "no size", text: version + "oid sha256:\(oid)\n",
              error: "invalid size: \"\""),
        .init(name: "size not a number", text: version + "oid sha256:\(oid)\nsize 12a\n",
              error: "invalid size: \"12a\""),
        .init(name: "extension with a bad oid", text: version + "ext-0-foo sha256:xyz\noid sha256:\(oid)\nsize 12345\n",
              error: "Invalid OID: xyz"),
        .init(name: "duplicate extension priority",
              text: version + "ext-0-foo sha256:\(otherOID)\next-0-bar sha256:\(otherOID)\noid sha256:\(oid)\nsize 12345\n",
              error: "duplicate priority found: 0"),
    ]
}
