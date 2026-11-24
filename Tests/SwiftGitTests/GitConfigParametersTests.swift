// GIT_CONFIG_PARAMETERS as git v2.54.0's config.c writes and reads it
// (issue #260). The expected strings are what `git -c … ` hands its
// children, as `sh -c 'printf %s "$GIT_CONFIG_PARAMETERS"'` shows.
import Testing
@testable import SwiftGit

@Suite("GIT_CONFIG_PARAMETERS codec")
struct GitConfigParametersTests {

    private func push(_ operands: [String], onto start: String? = nil) -> String? {
        operands.reduce(start) { GitConfigParameters.push($1, onto: $0) }
    }

    private struct Entry: Equatable {
        let key: String
        let value: String?
    }

    private func read(_ text: String) throws -> [Entry] {
        var entries: [Entry] = []
        try GitConfigParameters.entries(text) { entries.append(Entry(key: $0, value: $1)) }
        return entries
    }

    @Test("split at the first '=', a missing value written as an implicit boolean")
    func writing() {
        #expect(push(["a.b=1"]) == "'a.b'='1'")
        #expect(push(["a.b"]) == "'a.b'=")
        #expect(push(["a.b="]) == "'a.b'=''")
        #expect(push(["x.y=1=2"]) == "'x.y'='1=2'")
        #expect(push(["=v"]) == "''='v'")
        #expect(push([""]) == "''=")
        #expect(push(["a.b=1", "c.d"]) == "'a.b'='1' 'c.d'=")
        #expect(push(["c.d=2"], onto: "'a.b'='1'") == "'a.b'='1' 'c.d'='2'")
        #expect(push(["c.d=2"], onto: "") == "'c.d'='2'")
    }

    @Test("quote and bang step out of the quotes; the rest is kept as is")
    func quoting() {
        #expect(GitConfigParameters.quote("it's") == "'it'\\''s'")
        #expect(GitConfigParameters.quote("wow!") == "'wow'\\!''")
        #expect(GitConfigParameters.quote("a\\b \"c\"\nü") == "'a\\b \"c\"\nü'")
    }

    @Test("'=', '\\'' and '!' are found before a combining mark, as git's bytes are")
    func combiningMarks() throws {
        // U+0301 joins the character before it into one Swift `Character`.
        #expect(push(["a.b=\u{301}x"]) == "'a.b'='\u{301}x'")
        #expect(GitConfigParameters.quote("'\u{301}!\u{301}") == "''\\''\u{301}'\\!'\u{301}'")
        #expect(try read("'a.b=\u{301}x' 'c.d'='\u{301}y'") == [
            Entry(key: "a.b", value: "\u{301}x"), Entry(key: "c.d", value: "\u{301}y")
        ])
        #expect(try GitClient.normalizedKey("S.e\u{301}.K") == "s.e\u{301}.k")
        #expect(throws: CommandLineConfigError(reason: "invalid key: a.\u{301}b")) {
            try GitClient.normalizedKey("a.\u{301}b")
        }
        #expect(throws: CommandLineConfigError(reason: "invalid key (newline): a.x\r\ny.z")) {
            try GitClient.normalizedKey("a.x\r\ny.z")
        }
    }

    @Test("what it writes reads back")
    func roundTrip() throws {
        let operands = ["a.b=1", "a.b", "a.c=", "x.y=1=2", "Sec.Sub Ü.Key=it's !ü \"q\" \\", "n.l=one\ntwo"]
        let text = try #require(push(operands))
        #expect(try read(text) == [
            Entry(key: "a.b", value: "1"), Entry(key: "a.b", value: nil), Entry(key: "a.c", value: ""),
            Entry(key: "x.y", value: "1=2"), Entry(key: "Sec.Sub Ü.Key", value: "it's !ü \"q\" \\"),
            Entry(key: "n.l", value: "one\ntwo")
        ])
    }

    @Test("legacy 'key=value' and 'key' words, and white space between words")
    func legacyForms() throws {
        #expect(try read("'a.b=legacy' 'c.d'\t'e.f'= \n 'g.h'='v'") == [
            Entry(key: "a.b", value: "legacy"), Entry(key: "c.d", value: nil),
            Entry(key: "e.f", value: nil), Entry(key: "g.h", value: "v")
        ])
        #expect(try read("'a.b=x=y'") == [Entry(key: "a.b", value: "x=y")])
        #expect(try read("") == [])
    }

    @Test("what git calls bogus", arguments: [
        ("'a.b", "bogus format in GIT_CONFIG_PARAMETERS"),
        ("a.b=1", "bogus format in GIT_CONFIG_PARAMETERS"),
        (" 'a.b'='1'", "bogus format in GIT_CONFIG_PARAMETERS"),
        ("'a.b'x", "bogus format in GIT_CONFIG_PARAMETERS"),
        ("'a.b'=x", "bogus format in GIT_CONFIG_PARAMETERS"),
        ("'a.b'='x'y", "bogus format in GIT_CONFIG_PARAMETERS"),
        ("'a.b'='1''c.d'", "bogus format in GIT_CONFIG_PARAMETERS"),
        ("'a.b'='x", "bogus format in GIT_CONFIG_PARAMETERS"),
        ("'=x'", "bogus config parameter: =x"),
        ("''", "bogus config parameter: ")
    ])
    func bogus(_ text: String, _ reason: String) {
        #expect(throws: CommandLineConfigError(reason: reason)) { try read(text) }
    }

    @Test("entries before a bogus word are handed on first, in order")
    func stopsAtTheFirstBadWord() throws {
        var seen: [String] = []
        #expect(throws: CommandLineConfigError(reason: "bogus format in GIT_CONFIG_PARAMETERS")) {
            try GitConfigParameters.entries("'a.b'='1' 'c.d'x 'e.f'") { key, _ in seen.append(key) }
        }
        #expect(seen == ["a.b"])
    }

    @Test("GIT_CONFIG_COUNT's entries come first, then GIT_CONFIG_PARAMETERS', keys checked in order")
    func commandLineConfigOrder() throws {
        let entries = try GitClient.commandLineConfig([
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "A.B", "GIT_CONFIG_VALUE_0": "count",
            "GIT_CONFIG_PARAMETERS": "'a.b'='param' 'c.d'= 'e.f'=''"
        ])
        #expect(entries == [
            .init(name: "a.b", value: "count"), .init(name: "a.b", value: "param"),
            .init(name: "c.d", value: nil), .init(name: "e.f", value: "")
        ])
        #expect(throws: CommandLineConfigError(reason: "invalid key: a.1b")) {
            try GitClient.commandLineConfig(["GIT_CONFIG_PARAMETERS": "'a.1b'='x' 'bogus"])
        }
        #expect(throws: CommandLineConfigError(reason: "empty config key")) {
            try GitClient.commandLineConfig(["GIT_CONFIG_PARAMETERS": "''='x'"])
        }
    }

    @Test("a valueless entry is written without '=', an empty one with an empty value")
    func configFileText() {
        let text = GitClient.commandLineConfigFile([.init(name: "a.b", value: nil), .init(name: "a.c", value: "")])
        #expect(text == "[a]\n\tb\n[a]\n\tc = \"\"\n")
    }
}
