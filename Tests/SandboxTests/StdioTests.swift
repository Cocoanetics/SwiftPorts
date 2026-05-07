import Foundation
import Testing
@testable import Sandbox

@Suite struct StdioTests {

    @Test func currentIsNilByDefault() {
        #expect(Stdio.current == nil)
    }

    @Test func staticAccessorsFallThroughToProcessHandlesWhenUnset() {
        // No override in scope → effective handles are the real
        // process standard streams.
        #expect(Stdio.stdin === FileHandle.standardInput)
        #expect(Stdio.stdout === FileHandle.standardOutput)
        #expect(Stdio.stderr === FileHandle.standardError)
    }

    @Test func overrideRoutesWritesIntoSuppliedHandles() async throws {
        // Pipes give us in-memory handles to inspect what `Stdio.stdout`
        // received.
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe  = Pipe()

        // Push a known input so the overridden stdin can be read.
        let stdinBytes = Data("hello-stdin\n".utf8)
        try inPipe.fileHandleForWriting.write(contentsOf: stdinBytes)
        try inPipe.fileHandleForWriting.close()

        let stdio = Stdio(
            stdin:  inPipe.fileHandleForReading,
            stdout: outPipe.fileHandleForWriting,
            stderr: errPipe.fileHandleForWriting)

        try await Stdio.$current.withValue(stdio) {
            // Inside the bound scope, the static accessors return the
            // override.
            #expect(Stdio.stdout === outPipe.fileHandleForWriting)
            #expect(Stdio.stderr === errPipe.fileHandleForWriting)
            #expect(Stdio.stdin  === inPipe.fileHandleForReading)

            // Writing through the static accessor lands in the pipe.
            Stdio.stdout.write(Data("from-stdout\n".utf8))
            Stdio.stderr.write(Data("from-stderr\n".utf8))

            // Reading from the static accessor pulls the bytes we
            // pushed in via the input pipe.
            let read = try Stdio.stdin.readToEnd()
            #expect(read == stdinBytes)
        }

        // After the binding goes out of scope, the override clears.
        #expect(Stdio.current == nil)

        // Drain the pipes the embedder wrote into.
        try outPipe.fileHandleForWriting.close()
        try errPipe.fileHandleForWriting.close()
        let outBytes = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        let errBytes = try errPipe.fileHandleForReading.readToEnd() ?? Data()
        #expect(String(decoding: outBytes, as: UTF8.self) == "from-stdout\n")
        #expect(String(decoding: errBytes, as: UTF8.self) == "from-stderr\n")
    }

    @Test func printRoutesThroughOverride() async throws {
        // Stdio.print is the stdlib-print replacement that honours the
        // override; stdlib `print` would bypass it (writes to fd 1
        // directly via _stdoutImp).
        let outPipe = Pipe()

        let stdio = Stdio(stdout: outPipe.fileHandleForWriting)

        try await Stdio.$current.withValue(stdio) {
            Stdio.print("a", "b", "c")
            Stdio.print("done", terminator: "")
        }

        try outPipe.fileHandleForWriting.close()
        let bytes = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        #expect(String(decoding: bytes, as: UTF8.self) == "a b c\ndone")
    }
}

/// Mirrors `AmbientAPIBanTests` for the `Stdio` migration: enforces
/// that production sources outside `Sources/Sandbox/` don't reach for
/// `FileHandle.standardInput/Output/Error` or the stdlib `print(_:)`.
/// Both bypass ``Stdio/current`` and break embedded pipeline use.
@Suite struct StdioMigrationBanTests {

    private static let bannedNeedles: [(String, String)] = [
        ("FileHandle.standardInput",
         "use Stdio.stdin so `Stdio.current` overrides apply"),
        ("FileHandle.standardOutput",
         "use Stdio.stdout so `Stdio.current` overrides apply"),
        ("FileHandle.standardError",
         "use Stdio.stderr so `Stdio.current` overrides apply"),
    ]

    @Test func noBannedStdioAPIsInSources() throws {
        let sourcesURL = repoRoot().appendingPathComponent("Sources", isDirectory: true)
        let sandboxURL = sourcesURL.appendingPathComponent("Sandbox", isDirectory: true)
        let sandboxComponents = sandboxURL.standardizedFileURL.pathComponents

        let allSwiftFiles = try collectSwiftFiles(under: sourcesURL)
        let auditFiles = allSwiftFiles.filter { file in
            let fileComponents = file.standardizedFileURL.pathComponents
            guard fileComponents.count > sandboxComponents.count else { return true }
            return Array(fileComponents.prefix(sandboxComponents.count))
                != sandboxComponents
        }

        var violations: [(file: URL, line: Int, needle: String, advice: String)] = []

        for file in auditFiles {
            let body: String
            do {
                body = try String(contentsOf: file, encoding: .utf8)
            } catch {
                continue
            }
            let lines = body.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//")
                    || trimmed.hasPrefix("*")
                    || trimmed.hasPrefix("/*") {
                    continue
                }
                for (needle, advice) in Self.bannedNeedles {
                    if line.contains(needle) {
                        violations.append((
                            file: file,
                            line: idx + 1,
                            needle: needle,
                            advice: advice))
                    }
                }
            }
        }

        if !violations.isEmpty {
            let message = violations.map { v in
                "\(v.file.path):\(v.line) — found `\(v.needle)`; \(v.advice)"
            }.joined(separator: "\n")
            Issue.record(
                "\(violations.count) Stdio-migration ban violation(s) in Sources/:\n\(message)")
        }
    }

    @Test func noStdlibPrintInSources() throws {
        // Stdlib `print(_:separator:terminator:)` writes to fd 1
        // directly, bypassing `Stdio.current`. Sources should use
        // `Stdio.print(...)` instead.
        let sourcesURL = repoRoot().appendingPathComponent("Sources", isDirectory: true)
        let sandboxURL = sourcesURL.appendingPathComponent("Sandbox", isDirectory: true)
        let sandboxComponents = sandboxURL.standardizedFileURL.pathComponents

        let allSwiftFiles = try collectSwiftFiles(under: sourcesURL)
        let auditFiles = allSwiftFiles.filter { file in
            let fileComponents = file.standardizedFileURL.pathComponents
            guard fileComponents.count > sandboxComponents.count else { return true }
            return Array(fileComponents.prefix(sandboxComponents.count))
                != sandboxComponents
        }

        var violations: [(file: URL, line: Int)] = []
        // Match `print(` only when not preceded by an identifier
        // character or a `.` — i.e. a top-level call rather than a
        // member access (`Stdio.print(`) or an identifier suffix.
        // Swift Regex doesn't support lookbehind, so we do the same
        // check by hand below.
        func containsBareStdlibPrintCall(_ line: String) -> Bool {
            var search = Substring(line)
            while let range = search.range(of: "print(") {
                let preceding: Character?
                if range.lowerBound > search.startIndex {
                    preceding = search[search.index(before: range.lowerBound)]
                } else {
                    preceding = nil
                }
                let isMember = (preceding.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } ?? false)
                if !isMember {
                    return true
                }
                // Skip past this hit and keep looking.
                search = search[range.upperBound...]
            }
            return false
        }

        for file in auditFiles {
            let body: String
            do {
                body = try String(contentsOf: file, encoding: .utf8)
            } catch {
                continue
            }
            let lines = body.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//")
                    || trimmed.hasPrefix("*")
                    || trimmed.hasPrefix("/*") {
                    continue
                }
                // Skip protocol/method declarations named `print` —
                // rare but legitimate (e.g. `Output.swift`'s
                // `Printer.print(_:)`). Match `func ... print(`.
                if line.contains("func print(") || line.contains("func print<") {
                    continue
                }
                if containsBareStdlibPrintCall(line) {
                    violations.append((file: file, line: idx + 1))
                }
            }
        }

        if !violations.isEmpty {
            let message = violations.map { v in
                "\(v.file.path):\(v.line) — found stdlib `print(`; use `Stdio.print(...)` so embedded pipelines work"
            }.joined(separator: "\n")
            Issue.record(
                "\(violations.count) stdlib `print` site(s) in Sources/:\n\(message)")
        }
    }

    // MARK: - Helpers (duplicated from AmbientAPIBanTests so the suites
    // stay independent — the originals are file-private to that suite).

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func collectSwiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" {
                result.append(url)
            }
        }
        return result
    }
}
