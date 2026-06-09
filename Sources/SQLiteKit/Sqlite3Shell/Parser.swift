import Foundation
import SQLiteKit

/// Hand-rolled argv parser for the `sqlite3` CLI. SQLite uses single-dash
/// long options (`-csv`, `-header`, `-separator X`), which ArgumentParser
/// can't express, so — like the `rg` / `fd` ports — we parse argv directly.
enum Parser {
    struct Options {
        var databasePath: String?
        var sql: [String] = []
        var mode: OutputMode = .list
        var showHeader = false
        var headerExplicit = false
        var separator = "|"
        var nullValue = ""
        var readonly = false
        var interactive = false
        var echo = false
        var bail = false
        var safe = false
        var initFile: String?
        var commands: [String] = []
        var special: Special = .none
    }

    enum Special { case none, help, version }

    struct ArgError: Error { let message: String }

    static func parse(_ argv: [String]) throws -> Options {
        var options = Options()
        var positionals: [String] = []
        var i = 0

        func value(for flag: String) throws -> String {
            guard i + 1 < argv.count else {
                throw ArgError(message: "option requires an argument: \(flag)")
            }
            i += 1
            return argv[i]
        }

        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "-help", "--help", "-?": options.special = .help
            case "-version", "--version": options.special = .version
            case "-csv": options.mode = .csv
            case "-json": options.mode = .json
            case "-line": options.mode = .line
            case "-column": options.mode = .column
            case "-list": options.mode = .list
            case "-tabs": options.mode = .tabs
            case "-ascii": options.mode = .ascii
            case "-html": options.mode = .html
            case "-markdown": options.mode = .markdown
            case "-table": options.mode = .table
            case "-box": options.mode = .box
            case "-quote": options.mode = .quote
            case "-header", "-headers": options.showHeader = true; options.headerExplicit = true
            case "-noheader", "-noheaders": options.showHeader = false; options.headerExplicit = true
            case "-readonly": options.readonly = true
            case "-batch": options.interactive = false
            case "-interactive": options.interactive = true
            case "-echo": options.echo = true
            case "-bail": options.bail = true
            case "-safe": options.safe = true
            case "-separator": options.separator = try value(for: arg)
            case "-nullvalue": options.nullValue = try value(for: arg)
            case "-init": options.initFile = try value(for: arg)
            case "-cmd": options.commands.append(try value(for: arg))
            default:
                if arg.hasPrefix("-") && arg.count > 1 {
                    throw ArgError(message: "unknown option: \(arg)")
                }
                positionals.append(arg)
            }
            i += 1
        }

        if let first = positionals.first {
            options.databasePath = first
            options.sql = Array(positionals.dropFirst())
        }
        return options
    }

    static let helpText = """
    Usage: sqlite3 [OPTIONS] FILENAME [SQL]

    FILENAME is the SQLite database to open. Omit it (or use ":memory:")
    for a transient in-memory database. A trailing SQL argument runs and
    then exits; otherwise SQL is read from standard input.

    OPTIONS:
      -version           show the SQLite library version and exit
      -help              show this message and exit
      -readonly          open the database read-only
      -init FILE         run FILE before reading the main input
      -cmd COMMAND       run COMMAND before reading the main input
      -echo              print each statement before running it
      -bail              stop after the first error
      -batch             non-interactive mode
      -interactive       interactive mode (prompts; SQL run line-by-line)
      -safe              refuse dot-commands that touch the filesystem/shell

      -list              values separated by .separator (default)
      -csv               comma-separated values
      -tabs              tab-separated values
      -ascii             0x1F/0x1E separated values
      -column            left-aligned columns
      -markdown          Markdown table
      -table             ASCII-art table
      -box               Unicode box-drawing table
      -line              one value per line
      -json              JSON array of objects
      -html              HTML <TR>/<TD> rows
      -quote             SQL-literal values
      -header / -noheader  show or hide column headers
      -separator SEP     field separator for -list mode (default "|")
      -nullvalue STR     text to print for NULL values (default "")

    Dot-commands (at a statement boundary):
      .tables [PATTERN]  list tables and views
      .schema [TABLE]    show CREATE statements
      .databases         list attached databases
      .indexes [TABLE]   list indexes
      .mode MODE [TABLE] set output mode (list/csv/tabs/ascii/column/
                         markdown/table/box/line/json/html/quote/insert)
      .headers on|off    show or hide headers
      .separator SEP     set the -list separator
      .nullvalue STR     set the NULL placeholder
      .width N1 N2 ...   set column widths (negative right-justifies, 0 auto)
      .limit [NAME [VAL]]  show or set run-time limits
      .dump [TABLE]      dump the database (or one table) as SQL
      .fullschema        show the schema plus the ANALYZE (stat) tables
      .echo on|off       echo each statement before running it
      .bail on|off       stop after an error
      .changes on|off    report changed-row counts after each statement
      .eqp on|off        print the query plan before each statement
      .print TEXT...     print TEXT
      .import FILE TABLE import delimited FILE into TABLE
      .output [FILE]     send output to FILE (stdout if omitted)
      .once FILE         send the next command's output to FILE
      .read FILE         run SQL from FILE
      .open FILE         close the current database and open FILE
      .backup [DB] FILE  back up the database to FILE
      .restore [DB] FILE restore the database from FILE
      .show              show current settings
      .help              show this message
      .quit / .exit      exit

    """
}
