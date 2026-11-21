#if os(macOS) || os(Linux)
import Foundation
import Testing
import GitLFSTestSupport
@testable import GitLFSKit

@Suite("LFS filter git-lfs 3.7.1 process parity", .enabled(if: LFSOracle.isVersion371Available),
       .timeLimit(.minutes(5)))
struct LFSFilterOracleTests {
    @Test("add stages identical pointer bytes and git blob oid",
           arguments: [0, 1, 1023, 1024, 1025, 200_003])
    func add(length: Int) throws {
        let fixture = try LFSFilterOracleFixture()
        defer { fixture.cleanup() }
        let bytes = Data(repeating: 0x61, count: length)
        try fixture.seed(bytes)
        let pointer = try fixture.system(["show", ":a.lfs"])
        let oid = try fixture.system(["rev-parse", ":a.lfs"])
        // Force real Git to run clean; an unchanged index entry can reuse its cached stat.
        try fixture.system(["rm", "--cached", "-q", "a.lfs"])
        let reference = try fixture.run(["add", "a.lfs"], reference: true)
        #expect(reference.status == 0)
        #expect(try fixture.system(["show", ":a.lfs"]) == pointer)
        #expect(try fixture.system(["rev-parse", ":a.lfs"]) == oid)
        let expected = Pointer(oid: LFSFilterFixture.hash(bytes), size: Int64(length))
        #expect(pointer == expected.encoded)
        if length > 0 {
            let stored = fixture.directory.appendingPathComponent(
                ".git/lfs/objects/\(expected.oid.prefix(2))/\(expected.oid.dropFirst(2).prefix(2))/\(expected.oid)")
            #expect(try Data(contentsOf: stored) == bytes)
        }
    }

    @Test("attributes and direction-specific commands match on add",
           arguments: ["absent", "unset", "other", "none", "clean", "smudge", "process", "required"])
    func gating(mode: String) throws {
        let fixture = try LFSFilterOracleFixture()
        defer { fixture.cleanup() }
        let attribute = mode == "absent" ? "" : mode == "unset" ? "*.lfs -filter -text\n"
            : mode == "other" ? "*.lfs filter=other -text\n" : "*.lfs filter=lfs -text\n"
        try Data(attribute.utf8).write(to: fixture.directory.appendingPathComponent(".gitattributes"))
        for command in ["process", "clean", "smudge"] {
            _ = try fixture.run(["config", "--unset", "filter.lfs.\(command)"], reference: true)
        }
        try fixture.configure(["filter.lfs.required": mode == "required" ? "true" : "false"])
        if ["clean", "smudge", "process"].contains(mode) {
            try fixture.configure(["filter.lfs.\(mode)": "git-lfs " + (mode == "process" ? "filter-process" : mode)])
        }
        try Data("payload\n".utf8).write(to: fixture.directory.appendingPathComponent("a.lfs"))
        let actual = try fixture.run(["add", "a.lfs"])
        let ours = actual.status == 0 ? try fixture.system(["show", ":a.lfs"]) : nil
        if actual.status == 0 { try fixture.system(["rm", "--cached", "-q", "a.lfs"]) }
        let reference = try fixture.run(["add", "a.lfs"], reference: true)
        #expect(actual.status == reference.status)
        #expect(actual.stderr == reference.stderr)
        if reference.status == 0 { #expect(ours == (try fixture.system(["show", ":a.lfs"]))) }
    }

    @Test("checkout attributes and direction-specific commands match the reference",
           arguments: ["absent", "unset", "other", "none", "clean", "clean-empty", "smudge"], [false, true])
    func checkoutGating(mode: String, required: Bool) throws {
        let fixture = try LFSFilterOracleFixture()
        defer { fixture.cleanup() }
        try fixture.seed(Data("content\n".utf8))
        let attributes = mode == "absent" ? "" : mode == "unset" ? "*.lfs -filter -text\n"
            : mode == "other" ? "*.lfs filter=other -text\n" : "*.lfs filter=lfs -text\n"
        try Data(attributes.utf8).write(to: fixture.directory.appendingPathComponent(".gitattributes"))
        for command in ["clean", "smudge", "process"] {
            _ = try fixture.run(["config", "--unset", "filter.lfs.\(command)"], reference: true)
        }
        try fixture.configure(["filter.lfs.required": required ? "true" : "false"])
        if ["clean", "smudge"].contains(mode) {
            try fixture.configure(["filter.lfs.\(mode)": "git-lfs " + mode + " -- %f"])
        }
        if mode == "clean-empty" { try fixture.configure(["filter.lfs.clean": ""]) }
        let actual = try fixture.checkout(reference: false)
        let reference = try fixture.checkout(reference: true)
        #expect(actual.status == reference.status)
        #expect(actual.stderr == reference.stderr)
        if required && ["clean", "clean-empty"].contains(mode) {
            #expect(reference.status == 128)
            #expect(reference.stderr == "fatal: a.lfs: smudge filter lfs failed\n")
        }
        if actual.status == 0 { #expect(actual.bytes == reference.bytes) }
    }

    @Test("clean preserves existing pointers and hashes malformed and cutoff input",
           arguments: ["canonical", "noncanonical", "malformed", "cutoff-1023", "cutoff-1024"])
    func cleanPointers(mode: String) throws {
        let fixture = try LFSFilterOracleFixture()
        defer { fixture.cleanup() }
        let pointer = Pointer(oid: String(repeating: "b", count: 64), size: 42)
        var data = Data(pointer.encoded.utf8)
        switch mode {
        case "noncanonical": data = Data(pointer.encoded.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        case "malformed": data = Data("version https://git-lfs.github.com/spec/v1\noid sha256:bad\nsize 42\n".utf8)
        case "cutoff-1023": data.append(Data(repeating: 0x20, count: 1023 - data.count))
        case "cutoff-1024": data.append(Data(repeating: 0x20, count: 1024 - data.count))
        default: break
        }
        try fixture.seed(data)
        let actual = try fixture.system(["show", ":a.lfs"])
        let oid = try fixture.system(["rev-parse", ":a.lfs"])
        try fixture.system(["rm", "--cached", "-q", "a.lfs"])
        try fixture.system(["add", "a.lfs"])
        #expect(actual == (try fixture.system(["show", ":a.lfs"])))
        #expect(oid == (try fixture.system(["rev-parse", ":a.lfs"])))
    }

    @Test("skip, include/exclude and process precedence preserve exact checkout bytes",
           arguments: ["normal", "env-unset", "env-0", "env-1", "process-skip", "smudge-skip",
                       "process-wins", "empty-process", "include", "exclude"])
    func checkout(mode: String) throws {
        let fixture = try LFSFilterOracleFixture()
        defer { fixture.cleanup() }
        try fixture.seed(Data(repeating: 0x62, count: 200_003))
        var environment: [String: String] = [:]
        switch mode {
        case "env-0": environment["GIT_LFS_SKIP_SMUDGE"] = "0"
        case "env-1": environment["GIT_LFS_SKIP_SMUDGE"] = "1"
        case "process-skip": try fixture.configure(["filter.lfs.process": "git-lfs filter-process --skip"])
        case "smudge-skip":
            _ = try fixture.run(["config", "--unset", "filter.lfs.process"], reference: true)
            try fixture.configure(["filter.lfs.smudge": "git-lfs smudge --skip -- %f"])
        case "process-wins": try fixture.configure(["filter.lfs.smudge": "git-lfs smudge --skip -- %f"])
        case "empty-process": try fixture.configure(["filter.lfs.process": ""])
        case "include": try fixture.configure(["lfs.fetchinclude": "other/**"])
        case "exclude": try fixture.configure(["lfs.fetchexclude": "*.lfs"])
        default: break
        }
        let actual = try fixture.checkout(reference: false, environment: environment)
        let reference = try fixture.checkout(reference: true, environment: environment)
        #expect(actual.status == reference.status, "\(actual.stderr)\n\(reference.stderr)")
        if actual.status == 0 {
            #expect(actual.bytes == reference.bytes)
            #expect(try fixture.run(["status", "--porcelain"], environment: environment).stdout.isEmpty)
        } else {
            #expect(actual.stderr == reference.stderr)
        }
    }

    @Test("raw and malformed pointer-looking checkout input passes through exactly",
           arguments: ["", "raw\n", "version https://git-lfs.github.com/spec/v1\noid sha256:bad\nsize 3\n"])
    func malformed(text: String) throws {
        let fixture = try LFSFilterOracleFixture()
        defer { fixture.cleanup() }
        // Commit the raw blob with the driver disabled, then activate it for checkout.
        try fixture.configure(["filter.lfs.process": "", "filter.lfs.clean": "", "filter.lfs.required": "false"])
        try fixture.seed(Data(text.utf8))
        try fixture.configure(["filter.lfs.process": "git-lfs filter-process"])
        let actual = try fixture.checkout(reference: false)
        let reference = try fixture.checkout(reference: true)
        #expect(actual.status == reference.status)
        #expect(actual.bytes == reference.bytes)
        #expect(actual.bytes == Data(text.utf8))
    }

    @Test("server-backed clone sees isolated global filter config during checkout")
    func clone() async throws {
        try await LFSTestServer.withServer { server in
            let fixture = try LFSFilterOracleFixture()
            defer { fixture.cleanup() }
            let bytes = Data(repeating: 0x63, count: 200_003)
            try fixture.seed(bytes)
            server.store(bytes, oid: LFSFilterFixture.hash(bytes))
            let config = "[filter \"lfs\"]\nprocess = git-lfs filter-process\nrequired = true\n"
                + "[lfs]\nurl = \(server.endpoint.absoluteString)\n"
            try Data(config.utf8).write(to: fixture.host.globalConfig)
            for reference in [false, true] {
                let destination = fixture.host.root.appendingPathComponent(reference ? "reference" : "actual")
                let result = try fixture.run(["clone", fixture.directory.path, destination.path],
                    reference: reference, cwd: fixture.host.root)
                #expect(result.status == 0, "\(result.stderr)")
                #expect(try Data(contentsOf: destination.appendingPathComponent("a.lfs")) == bytes)
                #expect(try fixture.run(["status", "--porcelain"], reference: reference,
                    cwd: destination).stdout.isEmpty)
            }
            #expect(server.requests().filter { $0.method == "GET" }.count == 2)
        }
    }

    @Test("missing object and HTTP checkout failures preserve diagnostics and git exit status",
           arguments: ["required", "optional", "config", "env", "env-override", "http", "no-action",
                       "process", "process-optional", "process-suppressed"])
    func failures(mode: String) async throws {
        try await LFSTestServer.withServer { server in
            let fixture = try LFSFilterOracleFixture()
            defer { fixture.cleanup() }
            let bytes = Data("missing object\n".utf8)
            try fixture.seed(bytes)
            let oid = LFSFilterFixture.hash(bytes)
            let objects = fixture.directory.appendingPathComponent(".git/lfs/objects")
            try FileManager.default.removeItem(at: objects)
            try fixture.configure([
                "lfs.url": server.endpoint.absoluteString, "lfs.transfer.maxretries": "1",
                "filter.lfs.required": ["optional", "process-optional"].contains(mode) ? "false" : "true",
                "lfs.skipdownloaderrors": ["config", "env-override", "process-suppressed"].contains(mode)
                    ? "true" : "false"
            ])
            // Single-shot smudge makes the failure path independent of delayed-checkout scheduling.
            if !mode.hasPrefix("process") {
                _ = try fixture.run(["config", "--unset", "filter.lfs.process"], reference: true)
            }
            let environment = mode == "env" ? ["GIT_LFS_SKIP_DOWNLOAD_ERRORS": "1"]
                : mode == "env-override" ? ["GIT_LFS_SKIP_DOWNLOAD_ERRORS": "0"] : [:]
            if mode == "http" { server.inject(.repeatingServerError) }
            else if mode == "no-action" { server.inject(.noAction(oid: oid)) }
            else { server.inject(.objectStatus(oid: oid, code: 404)) }
            let actual = try fixture.checkout(reference: false, environment: environment)
            if mode == "no-action" { server.inject(.noAction(oid: oid)) }
            else if mode != "http" { server.inject(.objectStatus(oid: oid, code: 404)) }
            let reference = try fixture.checkout(reference: true, environment: environment)
            #expect(actual.status == reference.status, "\(actual.stderr)\n\(reference.stderr)")
            let actualDiagnostic = actual.stderr.split(separator: "\n").first {
                $0.hasPrefix("Error downloading object:")
            }
            let referenceDiagnostic = reference.stderr.split(separator: "\n").first {
                $0.hasPrefix("Error downloading object:")
            }
            #expect(actualDiagnostic != nil)
            #expect(actualDiagnostic == referenceDiagnostic)
            let actualFatal = actual.stderr.split(separator: "\n").filter {
                $0.hasPrefix("fatal:") || (mode.hasPrefix("process") && $0.hasPrefix("error: external filter"))
            }
            let referenceFatal = reference.stderr.split(separator: "\n").filter {
                $0.hasPrefix("fatal:") || (mode.hasPrefix("process") && $0.hasPrefix("error: external filter"))
            }
            #expect(actualFatal == referenceFatal)
            if actual.status == 0 { #expect(actual.bytes == reference.bytes) }
        }
    }

    @Test("optional process failure restores later ordinary checkout paths before failing")
    func mixedPathFailure() async throws {
        try await LFSTestServer.withServer { server in
            let fixture = try LFSFilterOracleFixture()
            defer { fixture.cleanup() }
            let bytes = Data("missing object\n".utf8)
            try fixture.seed(bytes)
            let ordinary = Data("ordinary tracked content\n".utf8)
            let ordinaryFile = fixture.directory.appendingPathComponent("z.txt")
            try ordinary.write(to: ordinaryFile)
            try fixture.system(["add", "z.txt"])
            try fixture.system(["-c", "core.hooksPath=/dev/null", "commit", "-qm", "ordinary"])
            try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent(".git/lfs/objects"))
            try fixture.configure([
                "lfs.url": server.endpoint.absoluteString, "lfs.transfer.maxretries": "1",
                "filter.lfs.required": "false", "lfs.skipdownloaderrors": "false"
            ])
            var results: [(files: [String: Data], stderr: String, status: Int32)] = []
            var states: [(diff: String, status: String)] = []
            for reference in [false, true] {
                let file = fixture.directory.appendingPathComponent("a.lfs")
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: ordinaryFile)
                server.inject(.objectStatus(oid: LFSFilterFixture.hash(bytes), code: 404))
                let result = try fixture.run(["checkout", "--", "a.lfs", "z.txt"], reference: reference)
                var files: [String: Data] = [:]
                files["a.lfs"] = FileManager.default.contents(atPath: file.path)
                files["z.txt"] = FileManager.default.contents(atPath: ordinaryFile.path)
                results.append((files, result.stderr, result.status))
                let diff = try fixture.run(["diff", "--", "a.lfs"], reference: reference)
                let status = try fixture.run(["status", "--porcelain"], reference: reference)
                #expect(diff.status == 0)
                #expect(status.status == 0)
                states.append((diff.stdout, status.stdout))
            }
            let actual = results[0]
            let reference = results[1]
            #expect(reference.status == 1)
            #expect(reference.files["z.txt"] == ordinary)
            #expect(actual.status == reference.status)
            #expect(actual.files == reference.files)
            #expect(states[1].status == " M a.lfs\n")
            #expect(!states[1].diff.isEmpty)
            #expect(states[0].status == states[1].status)
            #expect(states[0].diff == states[1].diff)
            let diagnostics: (String) -> [Substring] = { stderr in
                stderr.split(separator: "\n").filter {
                    $0.hasPrefix("Error downloading object:") || $0.hasPrefix("error: external filter")
                        || $0.hasPrefix("fatal:")
                }
            }
            #expect(diagnostics(actual.stderr) == diagnostics(reference.stderr))
        }
    }

    @Test("checkout selects branch, default, autodetected and fallback remotes",
           arguments: ["branch", "default", "autodetect", "search-all"])
    func remotes(mode: String) async throws {
        try await LFSTestServer.withServer { missing in
            try await LFSTestServer.withServer { backup in
                let fixture = try LFSFilterOracleFixture()
                defer { fixture.cleanup() }
                let bytes = Data("remote content\n".utf8)
                try fixture.seed(bytes)
                backup.store(bytes, oid: LFSFilterFixture.hash(bytes))
                try fixture.configure([
                    "remote.origin.url": "https://origin.example/repo.git",
                    "remote.origin.lfsurl": missing.endpoint.absoluteString,
                    "remote.backup.url": "https://backup.example/repo.git",
                    "remote.backup.lfsurl": backup.endpoint.absoluteString,
                    "lfs.transfer.maxretries": "1"
                ])
                switch mode {
                case "branch": try fixture.configure(["branch.main.remote": "backup"])
                case "default": try fixture.configure(["remote.lfsdefault": "backup"])
                case "autodetect":
                    try fixture.configure(["branch.main.remote": "origin", "lfs.remote.autodetect": "true"])
                    try fixture.system(["update-ref", "refs/remotes/backup/main", "HEAD"])
                default: try fixture.configure(["branch.main.remote": "origin", "lfs.remote.searchall": "true"])
                }
                for reference in [false, true] {
                    let objects = fixture.directory.appendingPathComponent(".git/lfs/objects")
                    try FileManager.default.removeItem(at: objects)
                    let result = try fixture.checkout(reference: reference)
                    #expect(result.status == 0, "\(mode): \(result.stderr)")
                    #expect(result.bytes == bytes)
                    #expect(try fixture.run(["status", "--porcelain"], reference: reference).stdout.isEmpty)
                }
                #expect(backup.requests().filter { $0.method == "GET" }.count == 2)
                #expect(missing.requests().isEmpty == (mode != "search-all"))
            }
        }
    }

    @Test("clone reports the checkout fatal and status, with optional and suppressed fallbacks",
           arguments: ["required", "optional", "suppressed", "process", "process-optional", "process-suppressed"])
    func cloneFailure(mode: String) async throws {
        try await LFSTestServer.withServer { server in
            let fixture = try LFSFilterOracleFixture()
            defer { fixture.cleanup() }
            let bytes = Data("missing in clone\n".utf8)
            try fixture.seed(bytes)
            let process = mode.hasPrefix("process")
            let required = !mode.contains("optional")
            let suppressed = mode.hasSuffix("suppressed")
            let config = "[filter \"lfs\"]\nsmudge = git-lfs smudge -- %f\nclean = git-lfs clean -- %f\n"
                + (process ? "process = git-lfs filter-process\n" : "")
                + "required = \(required ? "true" : "false")\n[lfs]\n"
                + "url = \(server.endpoint.absoluteString)\n"
                + "skipdownloaderrors = \(suppressed ? "true" : "false")\n"
                + "[lfs \"transfer\"]\nmaxretries = 1\n"
            try Data(config.utf8).write(to: fixture.host.globalConfig)
            var diagnostics: [String] = []
            var statuses: [Int32] = []
            for reference in [false, true] {
                let destination = fixture.host.root.appendingPathComponent(reference ? "reference" : "actual")
                let result = try fixture.run(["clone", fixture.directory.path, destination.path],
                    reference: reference, cwd: fixture.host.root)
                statuses.append(result.status)
                let lines = result.stderr.split(separator: "\n").filter {
                    $0.hasPrefix("Error downloading object:") || $0.hasPrefix("fatal:")
                        || (process && $0.hasPrefix("error: external filter"))
                        || $0.hasPrefix("warning:") || $0.hasPrefix("You can inspect") || $0.hasPrefix("and retry")
                }
                diagnostics.append(lines.joined(separator: "\n"))
                if result.status == 0 {
                    let expected = Pointer(oid: LFSFilterFixture.hash(bytes), size: Int64(bytes.count))
                    #expect(try Data(contentsOf: destination.appendingPathComponent("a.lfs"))
                        == Data(expected.encoded.utf8))
                }
            }
            let expected: Int32 = suppressed || (!required && !process) ? 0 : 128
            #expect(statuses == [expected, expected])
            #expect(diagnostics[0] == diagnostics[1])
        }
    }
}
#endif
