// git's config parser, transliterated: the line it refuses a file at, what
// it reads of one, and what its unset leaves of it.
import Foundation
import Testing
@testable import SwiftGit

@Suite("GitConfigFile")
struct GitConfigFileTests {

    /// What git 2.54 says of a file through `git config --file <f> --list`:
    /// the line it refuses, or the entries it lists.
    enum Verdict: Equatable {
        case refused(line: Int)
        case entries([String])
    }

    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Each checked against `/usr/bin/git` 2.54.0.
    static let cases: [(file: [UInt8], verdict: Verdict)] = [
        (bytes("[a]\n\tb = \"unterminated\n"), .refused(line: 2)),
        (bytes("[a]\n\tb = \"c\n"), .refused(line: 2)),
        (bytes("[a]\n\tb = c\\q\n"), .refused(line: 2)),
        (bytes("[a]\n\tb_c = d\n"), .refused(line: 2)),
        (bytes("[a]\n\t1b = c\n"), .refused(line: 2)),
        (bytes("[a]\n\tb.c = d\n"), .refused(line: 2)),
        (bytes("[a]\n\t= c\n"), .refused(line: 2)),
        (bytes("[a b]\n"), .refused(line: 1)),
        (bytes("[a \"b]\n"), .refused(line: 1)),
        (bytes("[a \"b\" x]\n"), .refused(line: 1)),
        (bytes("[a$]\n"), .refused(line: 1)),
        (bytes("[]\n"), .refused(line: 1)),
        (bytes("[a] x\n"), .entries(["a.x"])),
        (bytes("[a] x = y\n"), .entries(["a.x=y"])),
        (bytes("[a]\n\tb = c\\\n"), .entries(["a.b=c"])),
        (bytes("b = c\n"), .entries(["b=c"])),
        ([0xEF, 0xBB, 0xBF] + bytes("[a]\n\tb = c\n"), .entries(["a.b=c"])),
        ([0xEF, 0xBB] + bytes("[a]\n\tb = c\n"), .refused(line: 1)),
        (bytes("[a]\n\tb = \"c\" d \"e\"\n"), .entries(["a.b=c d e"])),
        (bytes("[a]\n\tb = \"x\\\ny\"\n"), .entries(["a.b=xy"])),
        (bytes("[a]\n\tb = c # comment\n"), .entries(["a.b=c"])),
        (bytes("[a]\n\tb = \"c # not comment\"\n"), .entries(["a.b=c # not comment"])),
        (bytes("[a]\n\tb = c\r\n"), .entries(["a.b=c"])),
        (bytes("[a\n"), .refused(line: 1)),
        (bytes("[a]]\n"), .refused(line: 1)),
        (bytes("[a] = b\n"), .refused(line: 1)),
        (bytes("[a]\nb c\n"), .refused(line: 2)),
        (bytes("[a]\nb\n"), .entries(["a.b"])),
        (bytes("[a]\n-b = c\n"), .refused(line: 2)),
        (bytes("[a]\nb- = c\n"), .entries(["a.b-=c"])),
        (bytes("[a.b.c]\nx = y\n"), .entries(["a.b.c.x=y"])),
        (bytes("[a \"b\\\"c\"]\nx = y\n"), .entries(["a.b\"c.x=y"])),
        (bytes("[a \"b\"]x = y\n"), .entries(["a.b.x=y"])),
        (bytes("[a \"b\" ]\n"), .refused(line: 1)),
        (bytes("[ a ]\n"), .refused(line: 1)),
        (bytes("[a]\n\tb = c\\\n\td\n"), .entries(["a.b=c\td"])),
        (bytes("[a]\n\tb = c\\\n# d\n"), .entries(["a.b=c"])),
        (bytes("[a]\n\tb = c\\\n\n"), .entries(["a.b=c"])),
        (bytes("[a]\n\tb = \\\n"), .entries(["a.b="])),
        (bytes("[a]\n\tb = c\\\nd"), .entries(["a.b=cd"])),
        (bytes("[a]\n\tb = c\\\n\td\n[c\n"), .refused(line: 4)),
        (bytes("[a]\n\tb = c\\\n[c]\n"), .entries(["a.b=c[c]"])),
        (bytes("[a]\n\tb = c\\\n\tb = d\n"), .entries(["a.b=c\tb = d"])),
        (bytes("[a]\n\tb = \"c\\\n\td\"\n"), .entries(["a.b=c\td"])),
        (bytes("[a] [b]\n"), .entries([])),
        (bytes("[a]\n\tb = c\n\n\n[b\n"), .refused(line: 5)),
        (bytes("[a]\n\tb = c\n\n\n\tb = \"\n"), .refused(line: 5)),
        (bytes("[a]\n\tb = c\n\n\n\tb = \\q\n"), .refused(line: 5)),
        (bytes("[a]\n\tb = \\t\\n\\b\\\\\\\"\n"), .entries(["a.b=\t\n\u{08}\\\""])),
        (bytes("[a]\n\tb = \"\\t\"\n"), .entries(["a.b=\t"])),
        (bytes("[a]\n\tb =\n"), .entries(["a.b="])),
        (bytes("[a]\n\tb=c\n"), .entries(["a.b=c"])),
        (bytes("[a]\n  b = c  \n"), .entries(["a.b=c"])),
        (bytes("[a]\n\tb = c;d\n"), .entries(["a.b=c"])),
        (bytes("[a]\n\tb = c\\;d\n"), .refused(line: 2)),
        (bytes("[a]\n\tb = c\\#d\n"), .refused(line: 2)),
        (bytes("[a]\n\tb = 'c'\n"), .entries(["a.b='c'"])),
        (bytes("[a]\n\t\"b\" = c\n"), .refused(line: 2)),
        (bytes("[a]\n\tb = c\"\n"), .refused(line: 2))
    ]

    /// `key=value`, or the key alone, as `git config --list` prints an entry.
    private static func listing(_ entry: GitConfigFile.Entry) -> String {
        let key = String(decoding: entry.key, as: UTF8.self)
        guard let value = entry.value else { return key }
        return key + "=" + String(decoding: value, as: UTF8.self)
    }

    @Test("reads what git reads, and refuses what git refuses at git's line")
    func parity() {
        for (file, verdict) in Self.cases {
            let parsed = GitConfigFile.parse(Data(file))
            let label = Comment(rawValue: String(decoding: file, as: UTF8.self).debugDescription)
            switch verdict {
            case .refused(let line):
                #expect(parsed.badLine == line, label)
            case .entries(let expected):
                #expect(parsed.badLine == nil, label)
                #expect(parsed.entries.map(Self.listing) == expected, label)
            }
        }
    }

    #if os(macOS) || os(Linux)
    /// The system git's version, `major.minor`, from `git version 2.34.1`.
    private static func systemGitVersion() throws -> (Int, Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--version"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let words = output.split(separator: " ")
        guard words.count >= 3 else { return nil }
        let numbers = words[2].split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    @Test("the system git says the same of every case",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/git")))
    func systemGitAgrees() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        // git before 2.45 turned white space inside a value into spaces
        // (`parse_value` keeps it since); an older git is not asked about
        // the entries that hold a tab.
        let keepsWhitespace = try Self.systemGitVersion().map { $0 >= (2, 45) } ?? true
        for (contents, verdict) in Self.cases {
            try Data(contents).write(to: file)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["config", "--file", file.path, "--list"]
            process.environment = ["HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let label = Comment(rawValue: String(decoding: contents, as: UTF8.self).debugDescription)
            switch verdict {
            case .refused(let line):
                #expect(process.terminationStatus == 128, label)
                #expect(stderr == "fatal: bad config line \(line) in file \(file.path)\n", label)
            case .entries(let expected):
                #expect(process.terminationStatus == 0, label)
                if keepsWhitespace || !expected.contains(where: { $0.contains("\t") }) {
                    #expect(stdout == expected.map { $0 + "\n" }.joined(), label)
                }
            }
        }
    }
    #endif

    /// An unset of `key` (of its entry with `value`, when given) in `file`,
    /// and what git leaves of the file.
    private struct Removal {
        let file: String
        let key: String
        var value: String?
        let after: String
    }

    @Test("an unset cuts what git cuts: the entry's line, and a section it leaves empty unless a comment is by it")
    func removing() {
        let cases: [Removal] = [
            Removal(file: "[a]\n\tb = hello\n[c]\n\td = 1\n", key: "a.b", value: nil, after: "[c]\n\td = 1\n"),
            Removal(file: "[a]\n\tb = hello\n", key: "a.b", value: nil, after: ""),
            Removal(file: "# top\n[a]\n\tb = hello\n", key: "a.b", value: nil, after: "# top\n[a]\n"),
            Removal(file: "[a]\n\t# about b\n\tb = hello\n", key: "a.b", value: nil, after: "[a]\n\t# about b\n"),
            Removal(file: "[a]\n\tb = hello # trailing\n", key: "a.b", value: nil, after: ""),
            Removal(file: "[a] b = hello\n", key: "a.b", value: nil, after: ""),
            Removal(file: "[a]\n\tb = hello\n\tc = x\n", key: "a.b", value: nil, after: "[a]\n\tc = x\n"),
            Removal(file: "[a]\n\tc = x\n\tb = hello", key: "a.b", value: nil, after: "[a]\n\tc = x\n"),
            Removal(file: "[a]\r\n\tb = hello\r\n\tc = x\r\n", key: "a.b", value: nil, after: "[a]\r\n\tc = x\r\n"),
            Removal(file: "[a]\n\tb = hel\\\n\tlo\n\tc = x\n", key: "a.b", value: nil, after: "[a]\n\tc = x\n"),
            Removal(file: "[a]\n\tb = 1\n[a]\n\tb = 2\n", key: "a.b", value: "2", after: "[a]\n\tb = 1\n"),
            Removal(file: "[a]\n\tb = 1\n[a]\n\tb = 2\n", key: "a.b", value: "1", after: "[a]\n[a]\n\tb = 2\n"),
            Removal(file: "[x]\n\ty = 1\n[a]\n\tb = 2\n", key: "a.b", value: nil, after: "[x]\n\ty = 1\n"),
            Removal(file: "[x]\n\ty = 1\n\n[a]\n\tb = 2\n\n[z]\n\tw = 3\n", key: "a.b", value: nil,
                    after: "[x]\n\ty = 1\n[z]\n\tw = 3\n")
        ]
        for removal in cases {
            let (file, key, value, after) = (removal.file, removal.key, removal.value, removal.after)
            let parsed = GitConfigFile.parse(Data(file.utf8))
            let matched = parsed.entries.indices.filter { index in
                parsed.entries[index].key == Array(key.utf8)
                    && (value.map { parsed.entries[index].value == Array($0.utf8) } ?? true)
            }
            let label = Comment(rawValue: "\(key) \(value ?? "") in \(file.debugDescription)")
            #expect(matched.count == 1, label)
            #expect(String(decoding: parsed.removing(entriesAt: matched), as: UTF8.self) == after, label)
        }
    }
}
