import ArgumentParser
import Foundation
import ForgeKit
import GitLab
import Sandbox

struct RepoClone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a GitLab project to the local filesystem."
    )

    @Argument(help: "Project (OWNER/REPO, GROUP/SUB/REPO, HOST/...). Required.")
    var project: RepositoryReference

    @Argument(help: "Optional local destination directory.")
    var directory: String?

    @Flag(name: .long, help: "Use the HTTPS URL instead of SSH.")
    var https: Bool = false

    func run() async throws {
        let client = try await CommandContext.apiClient(host: project.host)
        let p: Project = try await client.get(
            "projects/\(project.encodedPath)")

        let cloneURL: URL
        if https {
            guard let url = p.httpUrlToRepo else { throw RepoCloneError.noHTTPS }
            cloneURL = url
        } else {
            guard let url = p.sshUrlToRepo else { throw RepoCloneError.noSSH }
            cloneURL = url
        }

        let dest = directory.map { Sandbox.resolve($0) }
        let git: any ForgeKit.GitClient = CommandContext.gitClient()
        Stdio.print("Cloning \(p.pathWithNamespace) from \(cloneURL.absoluteString)")
        try await git.clone(url: cloneURL, directory: dest)
        let where_ = directory ?? p.path
        Stdio.print("\(ANSI.green("✓")) Cloned into \(where_)")
    }
}

enum RepoCloneError: Error, LocalizedError {
    case noSSH
    case noHTTPS

    var errorDescription: String? {
        switch self {
        case .noSSH: return "Project doesn't expose an SSH URL — pass --https."
        case .noHTTPS: return "Project doesn't expose an HTTPS URL."
        }
    }
}
