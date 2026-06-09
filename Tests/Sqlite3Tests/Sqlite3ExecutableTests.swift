import Foundation
import ShellKit
import Testing
@testable import Sqlite3Shell
@testable import SQLiteKit

@Suite struct Sqlite3ExecutableTests {

    /// Drives the executable with a fake stdin and captures stdout/stderr
    /// via ShellKit's `OutputSink` / `InputSource` — same harness as the
    /// other CLI ports. Uses an in-memory database so no filesystem (and
    /// no sandbox authorization) is involved.
    private func run(_ argv: [String], input: String = "") async throws
        -> (stdout: String, stderr: String, exit: Int32) {
        let stdinSource: InputSource = .string(input)
        let stdoutSink = OutputSink()
        let stderrSink = OutputSink()

        let exit = try await Sqlite3Executable.run(
            argv: argv,
            stdin: stdinSource,
            stdout: stdoutSink,
            stderr: stderrSink)

        stdoutSink.finish()
        stderrSink.finish()
        return (await stdoutSink.readAllString(), await stderrSink.readAllString(), exit)
    }

    @Test func inlineSelect() async throws {
        let r = try await run([":memory:", "SELECT 1 + 1;"])
        #expect(r.exit == 0)
        #expect(r.stdout == "2\n")
    }

    @Test func crudViaStdin() async throws {
        let script = """
        CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, qty INTEGER);
        INSERT INTO t(name, qty) VALUES ('apple', 3), ('banana', 5);
        UPDATE t SET qty = qty + 1 WHERE name = 'apple';
        DELETE FROM t WHERE name = 'banana';
        SELECT * FROM t;
        """
        let r = try await run([":memory:"], input: script)
        #expect(r.exit == 0)
        #expect(r.stdout == "1|apple|4\n")
    }

    @Test func csvFlagWithHeader() async throws {
        // The `-csv` flag emits LF row terminators — sqlite3 reserves CRLF
        // for the `.mode csv` dot-command (see csvModeUsesCRLF).
        let r = try await run(["-csv", "-header", ":memory:", "SELECT 1 AS a, 'x' AS b;"])
        #expect(r.exit == 0)
        #expect(r.stdout == "a,b\n1,x\n")
    }

    @Test func jsonFlag() async throws {
        let r = try await run(["-json", ":memory:", "SELECT 1 AS a;"])
        #expect(r.stdout == "[{\"a\":1}]\n")
    }

    @Test func jsonBlob() async throws {
        let r = try await run(["-json", ":memory:", "SELECT x'00ff' AS b;"])
        #expect(r.stdout == "[{\"b\":\"\\u0000\\u00ff\"}]\n")
    }

    @Test func dotPrint() async throws {
        let r = try await run([":memory:"], input: ".print hello world\n.print \"quoted arg\"\n")
        #expect(r.stdout == "hello world\nquoted arg\n")
    }

    @Test func dotEcho() async throws {
        let r = try await run([":memory:"], input: ".echo on\n.headers on\nSELECT 1 AS a;\n")
        #expect(r.stdout == ".headers on\nSELECT 1 AS a;\na\n1\n")
    }

    @Test func dotChanges() async throws {
        let r = try await run([":memory:"],
            input: ".changes on\nCREATE TABLE t(x);\nINSERT INTO t VALUES(1),(2),(3);\n")
        #expect(r.stdout.contains("changes: 0   total_changes: 0"))
        #expect(r.stdout.contains("changes: 3   total_changes: 3"))
    }

    @Test func eqpShowsScanPlan() async throws {
        let r = try await run([":memory:"], input: "CREATE TABLE t(x);\n.eqp on\nSELECT * FROM t;\n")
        #expect(r.stdout == "QUERY PLAN\n`--SCAN t\n")
    }

    @Test func eqpShowsIndexSearch() async throws {
        let r = try await run([":memory:"], input: """
        CREATE TABLE t(id INTEGER, name TEXT);
        CREATE INDEX ix ON t(name);
        .eqp on
        SELECT * FROM t WHERE name = 'bob';
        """)
        #expect(r.stdout.contains("QUERY PLAN\n`--SEARCH t USING INDEX ix (name=?)"))
    }

    @Test func eqpOffStopsPlans() async throws {
        let r = try await run([":memory:"], input: ".eqp on\n.eqp off\nSELECT 1;\n")
        #expect(r.stdout == "1\n")
    }

    @Test func scriptContinuesAfterError() async throws {
        // A script keeps going after an error (exit 1), matching sqlite3.
        let r = try await run([":memory:"], input: "SELECT * FROM nope;\nSELECT 99;\n")
        #expect(r.exit == 1)
        #expect(r.stdout == "99\n")
        #expect(r.stderr.contains("no such table: nope"))
    }

    @Test func bailStopsAfterError() async throws {
        let r = try await run([":memory:"], input: ".bail on\nSELECT * FROM nope;\nSELECT 99;\n")
        #expect(r.exit == 1)
        #expect(r.stdout == "")
        #expect(r.stderr.contains("no such table: nope"))
    }

    /// Creates a unique temp directory removed at the end of `body`.
    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite3-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    @Test func dotOutputRedirectsThenReverts() async throws {
        try await withTempDir { dir in
            let file = dir.appendingPathComponent("out.txt")
            let r = try await run([":memory:"],
                input: ".output \(file.path)\nSELECT 1;\n.output\nSELECT 2;\n")
            #expect(r.stdout == "2\n")
            #expect(try String(contentsOf: file, encoding: .utf8) == "1\n")
        }
    }

    @Test func dotOnceRedirectsNextOnly() async throws {
        try await withTempDir { dir in
            let file = dir.appendingPathComponent("once.txt")
            let r = try await run([":memory:"],
                input: ".once \(file.path)\nSELECT 10;\nSELECT 20;\n")
            #expect(r.stdout == "20\n")
            #expect(try String(contentsOf: file, encoding: .utf8) == "10\n")
        }
    }

    @Test func dotImportIntoExistingTable() async throws {
        try await withTempDir { dir in
            let csv = dir.appendingPathComponent("data.csv")
            try "1,alice\n\"x,y\",bob\n".write(to: csv, atomically: true, encoding: .utf8)
            let r = try await run([":memory:"], input: """
            .mode csv
            CREATE TABLE t(id,name);
            .import \(csv.path) t
            .mode list
            SELECT id || '/' || name FROM t ORDER BY name;
            """)
            #expect(r.stdout == "1/alice\nx,y/bob\n")
        }
    }

    @Test func dotImportCreatesTableFromHeader() async throws {
        try await withTempDir { dir in
            let csv = dir.appendingPathComponent("data.csv")
            try "id,name\n1,alice\n2,bob\n".write(to: csv, atomically: true, encoding: .utf8)
            let r = try await run([":memory:"], input: """
            .mode csv
            .import \(csv.path) newt
            .mode list
            SELECT id, name FROM newt ORDER BY id;
            """)
            #expect(r.stdout == "1|alice\n2|bob\n")
        }
    }

    @Test func dotBackupAndRestore() async throws {
        try await withTempDir { dir in
            let backup = dir.appendingPathComponent("bk.db")
            let r1 = try await run([":memory:"], input: """
            CREATE TABLE t(id, name);
            INSERT INTO t VALUES(1,'alice'),(2,'bob');
            .backup \(backup.path)
            """)
            #expect(r1.exit == 0)
            // Restore the backup into a fresh in-memory database.
            let r2 = try await run([":memory:"], input: """
            .restore \(backup.path)
            SELECT id || '/' || name FROM t ORDER BY id;
            """)
            #expect(r2.stdout == "1/alice\n2/bob\n")
        }
    }

    @Test func boxFlag() async throws {
        let r = try await run(["-box", ":memory:", "SELECT 1 AS a;"])
        #expect(r.stdout == "┌───┐\n│ a │\n├───┤\n│ 1 │\n└───┘\n")
    }

    @Test func insertModeNamedTable() async throws {
        let r = try await run([":memory:"],
            input: "CREATE TABLE t(a);INSERT INTO t VALUES(1);\n.mode insert t\nSELECT * FROM t;\n")
        #expect(r.stdout == "INSERT INTO t VALUES(1);\n")
    }

    @Test func dumpRoundTrip() async throws {
        let r = try await run([":memory:"], input: """
        CREATE TABLE t(id INTEGER, name TEXT);
        INSERT INTO t VALUES (1,'alice'),(2,NULL);
        .dump
        """)
        #expect(r.exit == 0)
        #expect(r.stdout == """
        PRAGMA foreign_keys=OFF;
        BEGIN TRANSACTION;
        CREATE TABLE t(id INTEGER, name TEXT);
        INSERT INTO t VALUES(1,'alice');
        INSERT INTO t VALUES(2,NULL);
        COMMIT;
        """ + "\n")
    }

    @Test func dotModeAndHeadersFromStdin() async throws {
        let script = """
        .mode csv
        .headers on
        SELECT 1 AS a, 2 AS b;
        """
        let r = try await run([":memory:"], input: script)
        #expect(r.stdout == "a,b\r\n1,2\r\n")
    }

    @Test func dotModeColumnEnablesHeaders() async throws {
        // `.mode column` turns headers on (sqlite3 behavior).
        let r = try await run([":memory:"], input: ".mode column\nSELECT 1 AS a, 2 AS b;\n")
        #expect(r.stdout == "a  b\n-  -\n1  2\n")
    }

    @Test func columnFlagDoesNotEnableHeaders() async throws {
        // ...but the -column flag does not.
        let r = try await run(["-column", ":memory:", "SELECT 1 AS a, 2 AS b;"])
        #expect(r.stdout == "1  2\n")
    }

    @Test func explicitHeadersOffBeatsColumnMode() async throws {
        let r = try await run([":memory:"], input: ".headers off\n.mode column\nSELECT 1 AS a;\n")
        #expect(r.stdout == "1\n")
    }

    @Test func dotTablesAndSchema() async throws {
        let script = """
        CREATE TABLE foo(id INTEGER);
        CREATE TABLE bar(id INTEGER);
        .tables
        .schema foo
        """
        let r = try await run([":memory:"], input: script)
        #expect(r.stdout.contains("bar"))
        #expect(r.stdout.contains("foo"))
        #expect(r.stdout.contains("CREATE TABLE foo(id INTEGER);"))
    }

    @Test func inlinePrepareError() async throws {
        // Command-line SQL: "Error: in prepare, ..." and exit = SQLite code.
        let r = try await run([":memory:", "SELECT * FROM missing;"])
        #expect(r.exit == 1)
        #expect(r.stderr == "Error: in prepare, no such table: missing\n")
    }

    @Test func inlineRuntimeError() async throws {
        // Stepping failure: "Error: stepping, ... (code)" and exit = code.
        let r = try await run([":memory:",
            "CREATE TABLE x(a INTEGER NOT NULL); INSERT INTO x VALUES(NULL);"])
        #expect(r.exit == 19)
        #expect(r.stderr == "Error: stepping, NOT NULL constraint failed: x.a (19)\n")
    }

    @Test func scriptParseErrorWithCaret() async throws {
        let r = try await run([":memory:"], input: "SELEC 1;\n")
        #expect(r.exit == 1)
        #expect(r.stderr == "Parse error near line 1: near \"SELEC\": syntax error\n  SELEC 1;\n  ^--- error here\n")
    }

    @Test func dotReadMissingFileFailsExitCode() async throws {
        let r = try await run([":memory:"], input: ".read /no/such/file\n")
        #expect(r.exit == 1)
        #expect(!r.stderr.isEmpty)
    }

    @Test func scriptRuntimeErrorLineNumber() async throws {
        let r = try await run([":memory:"],
            input: "CREATE TABLE x(a INTEGER NOT NULL);\nINSERT INTO x VALUES(NULL);\n")
        #expect(r.exit == 1)
        #expect(r.stderr == "Runtime error near line 2: NOT NULL constraint failed: x.a (19)\n")
    }

    @Test func unknownDotCommandContinues() async throws {
        let r = try await run([":memory:"], input: ".bogus\nSELECT 1;\n")
        #expect(r.exit == 0)
        #expect(r.stderr.contains("unknown command"))
        #expect(r.stdout == "1\n")
    }

    @Test func quitStopsProcessing() async throws {
        let script = """
        SELECT 1;
        .quit
        SELECT 2;
        """
        let r = try await run([":memory:"], input: script)
        #expect(r.stdout == "1\n")
    }

    @Test func versionFlag() async throws {
        let r = try await run(["-version"])
        #expect(r.exit == 0)
        #expect(r.stdout.hasPrefix("3.50.4 "))
        #expect(r.stdout.hasSuffix(" (64-bit)\n"))
    }

    @Test func unknownOptionFails() async throws {
        let r = try await run(["-bogus", ":memory:"])
        #expect(r.exit == 1)
        #expect(r.stderr.contains("unknown option"))
    }

    // MARK: .dump fidelity + output parity (issue #43)

    @Test func dumpQuotesSpaceTableName() async throws {
        // A table name with a space must be double-quoted in the emitted
        // INSERT (the old code used the raw name → invalid, un-replayable SQL).
        let r = try await run([":memory:"], input: """
        CREATE TABLE "my table"(x);
        INSERT INTO "my table" VALUES(1);
        .dump
        """)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("INSERT INTO \"my table\" VALUES(1);"))
    }

    @Test func dumpQuotesKeywordTableName() async throws {
        // `order` is a SQL keyword, so the INSERT must quote it — verified
        // against the engine's own sqlite3_keyword_check, case-insensitively.
        let r = try await run([":memory:"], input: """
        CREATE TABLE "order"(x);
        INSERT INTO "order" VALUES(1);
        .dump
        """)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("INSERT INTO \"order\" VALUES(1);"))
    }

    @Test func dumpPreservesAutoincrementSequence() async throws {
        // sqlite3's .dump re-emits the AUTOINCREMENT high-water mark as a
        // sqlite_sequence INSERT — with no CREATE (the table is implicit) and,
        // for `.dump` specifically, no `DELETE FROM sqlite_sequence` (that is
        // `.recover`'s behavior; cf. shell.c dump_callback). We match it
        // byte-for-byte: sqlite3's own dump doesn't dedupe the row the table's
        // own inserts re-create on replay, so this is parity, not a "perfect"
        // counter reload — see PR #46 review.
        let r = try await run([":memory:"], input: """
        CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, v);
        INSERT INTO t(v) VALUES('a'),('b'),('c');
        DELETE FROM t WHERE id = 3;
        .dump
        """)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("INSERT INTO sqlite_sequence VALUES('t',3);"))
        #expect(!r.stdout.contains("CREATE TABLE sqlite_sequence"))
        #expect(!r.stdout.contains("DELETE FROM sqlite_sequence"))  // .dump ≠ .recover
    }

    @Test func dumpSingleTableOmitsSequence() async throws {
        // A single-table dump omits sqlite_sequence (matching sqlite3).
        let r = try await run([":memory:"], input: """
        CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, v);
        INSERT INTO t(v) VALUES('a');
        .dump t
        """)
        #expect(r.exit == 0)
        #expect(!r.stdout.contains("sqlite_sequence"))
    }

    @Test func jsonPreservesDuplicateAndOrderedColumns() async throws {
        // Hand-rolled JSON keeps column order and duplicate names (a dict
        // would reorder/collapse them) — matching sqlite3's -json.
        let r = try await run(["-json", ":memory:", "SELECT 2 AS b, 1 AS a, 3 AS a;"])
        #expect(r.stdout == "[{\"b\":2,\"a\":1,\"a\":3}]\n")
    }

    @Test func dotCommandInsideStringLiteralIsData() async throws {
        // A line beginning with "." inside an open string literal is data,
        // not a dot-command: it must not run `.tables`.
        let r = try await run([":memory:"], input: """
        CREATE TABLE marker(x);
        SELECT '
        .tables
        ' AS v;
        """)
        #expect(r.exit == 0)
        #expect(r.stdout.contains(".tables"))   // preserved as data
        #expect(!r.stdout.contains("marker"))   // .tables never executed
    }

    // MARK: dot-command coverage parity (issue #43)

    @Test func databasesShowsFileAndReadWrite() async throws {
        // sqlite3: "<name>: <"" if no file> <r/w|r/o>".
        let r = try await run([":memory:"], input: ".databases\n")
        #expect(r.stdout == "main: \"\" r/w\n")
    }

    @Test func schemaViewGetsColumnComment() async throws {
        // sqlite3 appends /* view(cols) */ (with identifier quoting) to a view.
        let r = try await run([":memory:"], input: """
        CREATE TABLE t(a, b);
        CREATE VIEW v AS SELECT a, b + 1 AS bb FROM t;
        .schema v
        """)
        #expect(r.stdout == "CREATE VIEW v AS SELECT a, b + 1 AS bb FROM t\n/* v(a,bb) */;\n")
    }

    @Test func showListsAllTwelveSettings() async throws {
        // sqlite3's .show: 12 labels right-justified to width 12.
        let r = try await run([":memory:"], input: ".show\n")
        let expected = [
            "        echo: off",
            "         eqp: off",
            "     explain: auto",
            "     headers: off",
            "        mode: list",
            "   nullvalue: \"\"",
            "      output: stdout",
            "colseparator: \"|\"",
            "rowseparator: \"\\n\"",
            "       stats: off",
            "       width: ",
            "    filename: :memory:",
        ].joined(separator: "\n") + "\n"
        #expect(r.stdout == expected)
    }

    @Test func schemaUnresolvableViewHasNoComment() async throws {
        // A view that can't be prepared (missing table) prints just its stored
        // CREATE — no bogus /* v() */ comment (matches sqlite3). [PR #48 review]
        let r = try await run([":memory:"], input: """
        CREATE VIEW v AS SELECT * FROM missing;
        .schema v
        """)
        #expect(r.stdout == "CREATE VIEW v AS SELECT * FROM missing;\n")
    }

    @Test func showReportsModeDerivedSeparators() async throws {
        // .mode csv changes the reported separators to , / \r\n. [PR #48 review]
        let r = try await run([":memory:"], input: ".mode csv\n.show\n")
        #expect(r.stdout.contains("colseparator: \",\""))
        #expect(r.stdout.contains("rowseparator: \"\\r\\n\""))
    }

    // MARK: - Parity batch (issue #43): generated cols, reals, csv, .width,
    // REPL, -safe, .limit, .fullschema. Each expectation is pinned against a
    // real sqlite3 used as the oracle.

    @Test func dumpExcludesGeneratedColumns() async throws {
        let script = """
        CREATE TABLE t(a INT, b INT, c INT GENERATED ALWAYS AS (a+b) VIRTUAL, d INT GENERATED ALWAYS AS (a*b) STORED);
        INSERT INTO t(a,b) VALUES(2,3);
        .dump
        """
        let r = try await run([":memory:"], input: script)
        #expect(r.stdout.contains("INSERT INTO t VALUES(2,3);"))
        #expect(!r.stdout.contains("VALUES(2,3,"))   // generated values excluded
    }

    @Test func fullPrecisionRealsInRoundTripModes() async throws {
        let q = try await run([":memory:"], input: ".mode quote\nSELECT 0.1+0.2, 3.14;\n")
        #expect(q.stdout == "0.3000000000000000445,3.140000000000000124\n")
        let j = try await run([":memory:"], input: ".mode json\nSELECT 0.1+0.2 AS a;\n")
        #expect(j.stdout == "[{\"a\":0.3000000000000000445}]\n")
    }

    @Test func csvModeUsesCRLF() async throws {
        let r = try await run([":memory:"], input: ".mode csv\n.headers on\nSELECT 1 AS a, 'x' AS b;\n")
        #expect(r.stdout == "a,b\r\n1,x\r\n")
    }

    @Test func widthWrapsAndRightJustifies() async throws {
        let wrap = try await run([":memory:"], input: ".mode column\n.headers off\n.width 3\nSELECT 'abcdef';\n")
        #expect(wrap.stdout == "abc\ndef\n")
        let rj = try await run([":memory:"], input: ".mode column\n.headers off\n.width -5\nSELECT 'ab';\n")
        #expect(rj.stdout == "   ab\n")
    }

    @Test func showReportsWidthAndColumnModeSuffix() async throws {
        let r = try await run([":memory:"], input: ".mode box\n.width 3 5\n.show\n")
        #expect(r.stdout.contains("mode: box --wrap 60 --wordwrap off --noquote"))
        #expect(r.stdout.contains("width: 3 5 "))
        #expect(r.stdout.contains("filename: :memory:"))
    }

    @Test func interactiveBannerAndPrompts() async throws {
        let r = try await run(["-interactive", ":memory:"], input: "SELECT 1;\n.quit\n")
        #expect(r.stdout == Session.banner + "sqlite> 1\nsqlite> ")
    }

    @Test func interactiveContinuationPrompt() async throws {
        let r = try await run(["-interactive", ":memory:"], input: "SELECT\n1;\n.quit\n")
        #expect(r.stdout == Session.banner + "sqlite>    ...> 1\nsqlite> ")
    }

    @Test func interactiveErrorFormat() async throws {
        let r = try await run(["-interactive", ":memory:"], input: "SELECT bad here;\n.quit\n")
        #expect(r.stderr.contains("Parse error: "))
        #expect(r.stderr.contains("^--- error here"))
    }

    @Test func safeModeBlocksFileCommandAndExits() async throws {
        let r = try await run(["-safe", ":memory:", ".backup x.db"])
        #expect(r.exit == 1)
        #expect(r.stderr == "line 0: cannot run .backup in safe mode\n")
    }

    @Test func safeModeRejectsRealFileOpenButAllowsMemory() async throws {
        let real = try await run(["-safe", ":memory:", ".open foo.db"])
        #expect(real.exit == 1)
        #expect(real.stderr == "line 0: cannot open disk-based database files in safe mode\n")
        let mem = try await run(["-safe", ":memory:"], input: ".open :memory:\nSELECT 7;\n")
        #expect(mem.exit == 0)
        #expect(mem.stdout == "7\n")
        // `.open :memory:` must open a true in-memory database, never resolve
        // to a real on-disk file named ":memory:" (regression guard).
        #expect(!FileManager.default.fileExists(atPath: ":memory:"))
    }

    @Test func safeModeBlocksAttachAndLoadExtension() async throws {
        // -safe gates SQL-level filesystem reach, not just dot-commands.
        let attach = try await run(["-safe", ":memory:", "ATTACH 'foo.db' AS x;"])
        #expect(attach.exit == 1)
        #expect(attach.stderr == "line 0: cannot run ATTACH in safe mode\n")
        let ext = try await run(["-safe", ":memory:", "SELECT load_extension('x');"])
        #expect(ext.exit == 1)
        #expect(ext.stderr == "line 0: cannot use the load_extension() function in safe mode\n")
        // A normal statement is unaffected; ATTACH is denied without -safe-ing SQL.
        let ok = try await run([":memory:"], input: "ATTACH ':memory:' AS y;\nSELECT 'ok';\n")
        #expect(ok.stdout == "ok\n")
    }

    @Test func attachIsGatedByTheSandbox() async throws {
        // A rooted sandbox confines ATTACH the same way it confines the db
        // file / .read / .open: a path outside the root is denied, one inside
        // is allowed. (No -safe here — this is the always-on sandbox gate.)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sqlite-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func run(_ sql: String) async throws -> (out: String, err: String, exit: Int32) {
            let shell = Shell(environment: Environment(
                variables: ProcessInfo.processInfo.environment,
                workingDirectory: root.path))
            shell.sandbox = .rooted(at: root)
            let out = OutputSink(), err = OutputSink()
            shell.stdout = out; shell.stderr = err
            let exit = try await Shell.$current.withValue(shell) {
                try await Sqlite3Executable.run(
                    argv: [":memory:", sql], stdin: .string(""), stdout: out, stderr: err)
            }
            out.finish(); err.finish()
            return (await out.readAllString(), await err.readAllString(), exit)
        }

        let outside = try await run("ATTACH '/etc/hosts' AS x;")
        #expect(outside.exit == 1)
        #expect(outside.err.contains("Error:"))           // sandbox denial reported

        let inside = root.appendingPathComponent("inside.db").path
        let allowed = try await run("ATTACH '\(inside)' AS x; SELECT 'ok';")
        #expect(allowed.exit == 0)
        #expect(allowed.out == "ok\n")
    }

    @Test func limitListsAndSets() async throws {
        let list = try await run([":memory:", ".limit"])
        #expect(list.stdout.contains("              length 1000000000"))
        #expect(list.stdout.contains("      worker_threads 0"))
        let set = try await run([":memory:"], input: ".limit column 5\n.limit column\n")
        #expect(set.stdout == "              column 5\n              column 5\n")
    }

    @Test func fullschemaNoStats() async throws {
        let r = try await run([":memory:"], input: "CREATE TABLE x(a);\n.fullschema\n")
        #expect(r.stdout == "CREATE TABLE x(a);\n/* No STAT tables available */\n")
    }

    @Test func filenameShownAsTyped() async throws {
        let r = try await run([":memory:", ".show"])
        #expect(r.stdout.contains("filename: :memory:"))
    }
}
