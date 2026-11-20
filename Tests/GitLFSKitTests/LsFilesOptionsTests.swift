import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit

@Suite("LFS ls-files selection and rendering")
struct LsFilesOptionsTests {
    private static let first = Pointer(oid: String(repeating: "a", count: 64), size: 12)
    private static let second = Pointer(oid: String(repeating: "b", count: 64), size: 34)
    private static let third = Pointer(oid: String(repeating: "c", count: 64), size: 56)

    private func withRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let (dir, client) = try await LFSFixture.make(host, "ls-files")
            try await body(dir, client)
        }
    }

    private func write(_ pointer: Pointer, _ name: String = "asset", in dir: URL) throws {
        try Data(pointer.encoded.utf8).write(to: dir.appendingPathComponent(name))
    }

    @discardableResult
    private func commit(_ client: GitClient) async throws -> String {
        try await client.add(paths: [])
        return try await client.commit(message: "pointers", author: nil, allowEmpty: false)
    }

    private func files(_ result: LFSCommandResult) throws -> [LsFilesObject] {
        #expect(result.status == 0 && result.stderr.isEmpty)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        if object["files"] is NSNull { return [] }
        let data = try JSONSerialization.data(withJSONObject: #require(object["files"]))
        return try JSONDecoder().decode([LsFilesObject].self, from: data)
    }

    @Test func indexTreeAndUnborn() async throws {
        try await withRepo { dir, client in
            var options = LsFilesOptions()
            options.json = true
            #expect(try files(await options.lsFiles([], client: client)).isEmpty)
            try write(Self.first, in: dir)
            try await client.add(paths: ["asset"])
            #expect(try files(await options.lsFiles([], client: client)).map(\.oid) == [Self.first.oid])
            let base = try await commit(client)
            try write(Self.second, in: dir)
            try await client.add(paths: ["asset"])
            #expect(try files(await options.lsFiles([], client: client)).map(\.oid) == [Self.second.oid])
            #expect(try files(await options.lsFiles([base], client: client)).map(\.oid) == [Self.first.oid])
            try write(.empty, in: dir)
            try await client.add(paths: ["asset"])
            // A zero-sized staged pointer must not hide the HEAD pointer.
            #expect(try files(await options.lsFiles([], client: client)).map(\.oid) == [Self.first.oid])
            #expect(try await GitScanner(client: client).scanIndex().first?.pointer.size == 0)
        }
    }

    @Test func historySelectionAndDeduplication() async throws {
        try await withRepo { dir, client in
            try write(Self.first, in: dir)
            let base = try await commit(client)
            try write(Self.second, in: dir)
            try await commit(client)
            try write(Self.third, in: dir)
            let tip = try await commit(client)
            var options = LsFilesOptions()
            options.json = true
            #expect(try files(await options.lsFiles([base, tip], client: client)).map(\.oid)
                    == [Self.third.oid, Self.second.oid])
            options.all = true
            #expect(try files(await options.lsFiles([], client: client)).map(\.oid)
                    == [Self.third.oid, Self.second.oid, Self.first.oid])
            options.deleted = true
            #expect(try files(await options.lsFiles([], client: client)).map(\.oid)
                    == [Self.third.oid, Self.second.oid, Self.first.oid])
            options.all = false
            #expect(try files(await options.lsFiles([tip], client: client)).map(\.oid) == [Self.third.oid])
            try await client.remove(paths: ["asset"])
            _ = try await client.commit(message: "delete", author: nil, allowEmpty: false)
            #expect(try files(await options.lsFiles([], client: client)).map(\.oid) == [Self.third.oid])
            options.deleted = false
            #expect(try files(await options.lsFiles([], client: client)).isEmpty)
        }
    }

    @Test func filtersAndIndependentObjectStates() async throws {
        try await withRepo { dir, client in
            for name in ["a.bin", "b.bin", "c.txt"] { try write(Self.first, name, in: dir) }
            try await commit(client)
            try Data(repeating: 120, count: 12).write(to: dir.appendingPathComponent("a.bin"))
            try await client.configSet("lfs.fetchinclude", "unrelated")
            try await client.configSet("lfs.fetchexclude", "*")
            var options = LsFilesOptions()
            options.json = true
            var rows = try files(await options.lsFiles([], client: client))
            #expect(rows.map(\.name) == ["a.bin", "b.bin", "c.txt"])
            #expect(rows.map(\.checkout) == [true, false, false])
            #expect(rows.allSatisfy { !$0.downloaded })
            let store = try await LocalStore.open(client)
            let object = try await store.objectPath(Self.first.oid)
            try Data(repeating: 120, count: 12).write(to: object)
            options.include = " *.bin/ , c.txt "
            options.exclude = "b.bin, c.txt"
            rows = try files(await options.lsFiles([], client: client))
            #expect(rows.map(\.name) == ["a.bin"] && rows.allSatisfy(\.downloaded))
        }
    }

    @Test func printerFieldsAndEscaping() async throws {
        // Exercise HTML-sensitive names without creating Windows-invalid paths.
        let escaped = LsFilesObject(name: "<>&", size: 12, checkout: false, downloaded: false,
                                    oidType: "sha256", oid: Self.first.oid, version: Pointer.latestVersion)
        #expect(escaped.json.contains("\\u003c\\u003e\\u0026"))
        try await withRepo { dir, client in
            let name = "a&\u{2028}.bin"
            try write(Self.first, name, in: dir)
            try write(.empty, "empty", in: dir)
            try await commit(client)
            var options = LsFilesOptions()
            options.json = true
            let json = try await options.lsFiles([], client: client)
            #expect(json.stdout.contains("a\\u0026\\u2028.bin"))
            let row = try #require(files(json).first)
            #expect(row.name == name && row.size == 12 && !row.checkout && !row.downloaded)
            #expect(row.oidType == "sha256" && row.oid == Self.first.oid && row.version == Pointer.latestVersion)
            options.json = false
            options.long = true
            options.size = true
            let long = try await options.lsFiles([], client: client)
            #expect(long.stdout.contains(Self.first.oid + " - " + name + " (12 B)"))
            options.nameOnly = true
            let names = try await options.lsFiles([], client: client)
            #expect(names.stdout == name + " (12 B)\n")
            options.debug = true
            options.json = true
            let debug = try await options.lsFiles([], client: client)
            #expect(debug.stdout.contains("checkout: false\ndownload: false"))
            #expect(debug.stdout.hasSuffix("\n\n{\n \"files\": null\n}\n"))
        }
    }

    @Test func invalidCombinationsAndRepository() async throws {
        try await withRepo { _, client in
            var options = LsFilesOptions()
            options.all = true
            let all = try await options.lsFiles(["HEAD"], client: client)
            #expect(all.status == 2 && all.stderr == "Cannot use --all with explicit reference\n")
            options.deleted = true
            options.all = false
            let range = try await options.lsFiles(["A", "B"], client: client)
            #expect(range.status == 2 && range.stderr == "Cannot use --deleted with reference range\n")
            options.deleted = false
            let missing = try await options.lsFiles(["missing-ref"], client: client)
            #expect(missing.status == 2 && missing.stderr.hasPrefix("Could not scan for Git LFS tree: "))
            let literalAll = try await options.lsFiles(["--all"], client: client)
            #expect(literalAll.status == 2 && literalAll.stderr == "Did you mean `git lfs ls-files --all --` ?\n")
        }
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let result = try await LsFilesOptions().lsFiles([], client: GitClient(workingDirectory: host.root))
            #expect(result.status == 128 && result.stdout == "Not in a Git repository.\n")
        }
    }
}
