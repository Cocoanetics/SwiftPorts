import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct IssueBoard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "board",
        abstract: "Manage a project's issue boards.",
        discussion: """
            The terminal kanban TUI from upstream glab is not ported
            here. For the kanban view, run `glab issue board view` (no
            ID) and it'll open the boards page in your browser, where
            GitLab's full drag-and-drop UI is available. The other
            subcommands (`list`, `view <id>`, `create`, `delete`) manage
            boards via the API.
            """,
        subcommands: [
            IssueBoardList.self,
            IssueBoardView.self,
            IssueBoardCreate.self,
            IssueBoardDelete.self,
        ]
    )
}

// MARK: - list

struct IssueBoardList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the issue boards on a project.",
        aliases: ["ls"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("P"), .customLong("per-page")],
            help: "Items per page.")
    var perPage: Int = 30

    @Option(name: [.customShort("p"), .long],
            help: "Page number.")
    var page: Int = 1

    @Flag(name: .long, help: "Print as JSON array.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let boards: [Board] = try await client.get(
            "projects/\(target.encodedPath)/boards",
            query: [
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ])

        if json {
            Stdio.print(try CodableOutput.prettyJSON(boards))
            return
        }
        if boards.isEmpty {
            Stdio.print("No boards on this project. Create one with `glab issue board create`.")
            return
        }
        for b in boards {
            let listCount = b.lists?.count ?? 0
            let columnsBit = listCount == 0
                ? ANSI.dim("(default columns only)")
                : ANSI.dim("(\(listCount) extra column\(listCount == 1 ? "" : "s"))")
            Stdio.print("#\(b.id)\t\(ANSI.bold(b.name))  \(columnsBit)")
        }
    }
}

// MARK: - view

struct IssueBoardView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Show a board's metadata, or open the board UI in your browser.",
        aliases: ["show"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Board ID. Omit to open the boards page in your browser.")
    var boardId: Int?

    @Flag(name: [.customShort("w"), .long],
          help: "Open in your browser even when an ID is given.")
    var web: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let host = target.host ?? Configuration.defaultHost

        if boardId == nil || web {
            let baseURL = URL(string: "https://\(host)/\(target.fullPath)/-/boards")!
            let url: URL
            if let boardId, web {
                url = baseURL.appendingPathComponent(String(boardId))
            } else {
                url = baseURL
            }
            try await Browser.open(url)
            Stdio.print("Opening \(url.absoluteString) in your browser.")
            return
        }

        let client = try await CommandContext.apiClient(host: target.host)
        let board: Board = try await client.get(
            "projects/\(target.encodedPath)/boards/\(boardId!)")

        if json {
            Stdio.print(try CodableOutput.prettyJSON(board))
            return
        }

        Stdio.print("\(ANSI.bold("#\(board.id)"))  \(ANSI.bold(board.name))")
        if let m = board.milestone { Stdio.print("milestone: \(m.title)") }
        if let a = board.assignee { Stdio.print("assignee scope: @\(a.username)") }
        if let labels = board.labels, !labels.isEmpty {
            Stdio.print("label scope: \(labels.map(\.name).joined(separator: ", "))")
        }
        if let weight = board.weight { Stdio.print("weight scope: \(weight)") }
        if let hb = board.hideBacklogList, hb { Stdio.print("backlog list: \(ANSI.dim("hidden"))") }
        if let hc = board.hideClosedList, hc { Stdio.print("closed list: \(ANSI.dim("hidden"))") }
        if let lists = board.lists, !lists.isEmpty {
            Stdio.print("\nColumns (between Open and Closed):")
            for list in lists {
                let labelName = list.label?.name ?? "—"
                let cap = list.maxIssueCount.map { ", max \($0) issues" } ?? ""
                Stdio.print("  \(labelName)\(ANSI.dim(" (#\(list.id), pos \(list.position ?? 0)\(cap))"))")
            }
        } else {
            Stdio.print("Columns: \(ANSI.dim("default Open / Closed only"))")
        }

        let url = URL(string: "https://\(host)/\(target.fullPath)/-/boards/\(board.id)")!
        Stdio.print("\nurl: \(url.absoluteString)")
    }
}

// MARK: - create

struct IssueBoardCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a project issue board.",
        aliases: ["new"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Board name. Mutually exclusive with -n.")
    var positionalName: String?

    @Option(name: [.customShort("n"), .long],
            help: "Board name. Mutually exclusive with the positional argument.")
    var name: String?

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    private struct CreateRequest: Encodable { let name: String }

    func run() async throws {
        if positionalName != nil && name != nil {
            throw IssueBoardCreateError.bothNamesGiven
        }
        guard let chosen = positionalName ?? name, !chosen.isEmpty else {
            throw IssueBoardCreateError.nameRequired
        }
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let board: Board = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/boards",
            body: CreateRequest(name: chosen))
        if json {
            Stdio.print(try CodableOutput.prettyJSON(board))
            return
        }
        Stdio.print("\(ANSI.green("✓")) Created board #\(board.id): \(ANSI.bold(board.name))")
    }
}

enum IssueBoardCreateError: Error, LocalizedError {
    case nameRequired
    case bothNamesGiven

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "Board name is required. Pass it as a positional argument or via -n/--name."
        case .bothNamesGiven:
            return "Pass the board name either positionally or via -n/--name, not both."
        }
    }
}

// MARK: - delete

struct IssueBoardDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a project issue board. Irreversible."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Board ID.")
    var boardId: Int

    @Flag(name: [.customShort("y"), .customLong("yes")],
          help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        if !yes {
            let board: Board = try await client.get(
                "projects/\(target.encodedPath)/boards/\(boardId)")
            Stdio.stderr.write(Data(
                "\(ANSI.red("⚠"))  About to delete board #\(boardId) \"\(board.name)\" on \(target.fullPath). This is irreversible.\nType the board name to confirm: ".utf8))
            guard let line = readLine(strippingNewline: true), line == board.name else {
                throw IssueBoardDeleteError.confirmationMismatch
            }
        }
        try await client.delete(
            "projects/\(target.encodedPath)/boards/\(boardId)")
        Stdio.print("\(ANSI.green("✓")) Deleted board #\(boardId).")
    }
}

enum IssueBoardDeleteError: Error, LocalizedError {
    case confirmationMismatch
    var errorDescription: String? {
        "Confirmation didn't match the board name; nothing was deleted."
    }
}
