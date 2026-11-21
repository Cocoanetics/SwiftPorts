import Foundation
import ShellKit
import SwiftGit

/// `git lfs checkout` (git-lfs 3.7.1 `commands/command_checkout.go`).
///
/// Restores eligible working-tree LFS pointers from the local object store
/// without downloading from any remote, or extracts a conflicted merge stage
/// (`--base` / `--ours` / `--theirs`) with `--to <path>`.
///
/// Note: refreshing the Git index stat cache after rewriting working-tree
/// files requires the in-process LFS clean filter to be registered via
/// ``GitLFSKit/installFilter()``.
public struct CheckoutOptions: Sendable {
    public var base = false
    public var ours = false
    public var theirs = false
    public var to: String?

    public init() {}

    public func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool = false
    ) async throws -> LFSCommandResult {
        try await run(arguments, client: client, git: git, terminal: terminal,
                      environment: LFSTransferEnvironment())
    }

    func run(
        _ arguments: [String], client: LFSClient, git: GitClient, terminal: Bool,
        environment: LFSTransferEnvironment
    ) async throws -> LFSCommandResult {
        do {
            let repo = try await LFSRepository.open(git, workTree: false)
            guard let workDir = repo.workingDirectory else {
                return LFSCommandResult(stdout: "This operation must be run in a work tree.\n")
            }
            let stage = try selectedStage()
            let rooted = try await Self.rootedPaths(
                arguments, workingDirectory: workDir, cwd: git.workingDirectory)
            let destination = to ?? ""
            if !destination.isEmpty && stage != nil {
                guard arguments.count == 1 else {
                    throw LFSFailure("--to requires exactly one Git LFS object file path")
                }
                return try await checkoutConflict(
                    file: rooted[0], stage: stage!, to: destination,
                    client: client, git: git, repository: repo)
            } else if !destination.isEmpty || stage != nil {
                throw LFSFailure("--to and exactly one of --theirs, --ours, and --base must be used together")
            }
            guard (try? await git.resolveOID("HEAD")) != nil else {
                throw LFSFailure("Could not checkout")
            }
            let store = try await LocalStore.open(git)
            var single = try await LFSSingleCheckout.make(
                git: git, store: store, repository: repo, configuration: client.finder.configuration)
            if single.skip {
                return LFSCommandResult(stdout: "Cannot checkout LFS objects, Git LFS is not installed.\n")
            }
            return try await checkoutWorkingTree(
                patterns: rooted, single: &single, client: client, git: git,
                terminal: terminal, environment: environment)
        } catch let failure as LFSFailure {
            return failure.result
        }
    }

    private func selectedStage() throws -> Int? {
        var stage: Int?
        var seen = 0
        if base { seen += 1; stage = 1 }
        if ours { seen += 1; stage = 2 }
        if theirs { seen += 1; stage = 3 }
        if seen > 1 {
            throw LFSFailure("Error parsing args: at most one of --base, --theirs, and --ours is allowed")
        }
        return stage
    }

    private func checkoutWorkingTree(
        patterns: [String], single: inout LFSSingleCheckout,
        client: LFSClient, git: GitClient, terminal: Bool, environment: LFSTransferEnvironment
    ) async throws -> LFSCommandResult {
        let meter = await LFSProgressMeter.make(
            direction: .checkout, display: true, terminal: terminal,
            configuration: client.finder.configuration, environment: environment)
        let scanner = GitScanner(client: git, filter: FilepathFilter(include: patterns))
        let pointers: [WrappedPointer]
        do {
            pointers = try await scanner.scanLFSFiles()
        } catch {
            throw LFSFailure(String(describing: error))
        }
        var totalBytes: Int64 = 0
        for pointer in pointers {
            totalBytes &+= pointer.pointer.size
            meter.add(pointer.pointer.size)
            meter.startTransfer(pointer.name)
        }
        meter.start()
        for pointer in pointers {
            await single.run(pointer)
            meter.transferBytes(
                pointer.name, read: pointer.pointer.size,
                total: totalBytes, current: pointer.pointer.size)
            meter.finishTransfer(pointer.name)
        }
        meter.finish()
        await single.close()
        return LFSCommandResult(stderr: single.stderr)
    }

    private func checkoutConflict(
        file: String, stage: Int, to destination: String,
        client: LFSClient, git: GitClient, repository: LFSRepository
    ) async throws -> LFSCommandResult {
        let targetURL = Self.absoluteTargetURL(destination, relativeTo: git.workingDirectory)
        let parentURL = targetURL.deletingLastPathComponent()
        do {
            try await Shell.authorize(parentURL)
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            throw LFSFailure("Could not create path \(targetURL.path.goQuoted): \(error)")
        }

        let store = try await LocalStore.open(git)
        var single = try await LFSSingleCheckout.make(
            git: git, store: store, repository: repository, configuration: client.finder.configuration)
        if single.skip {
            return LFSCommandResult(stdout: "Cannot checkout LFS objects, Git LFS is not installed.\n")
        }

        let spec = ":\(stage):\(file)"
        let entries = try await git.indexedEntries()
        guard let entry = entries.first(where: { $0.stage == stage && $0.path == file }) else {
            throw LFSFailure(
                "Could not checkout (are you not in the middle of a merge?): Git can't resolve ref: \(spec.goQuoted)")
        }
        let blob: Data
        do {
            blob = try await git.catFileBlob(entry.oid)
        } catch {
            throw LFSFailure("Could not find object \(entry.oid.goQuoted)")
        }
        let pointer: Pointer
        do {
            pointer = try Pointer.decode(blob)
        } catch {
            throw LFSFailure("Could not find decoder pointer for object \(entry.oid.goQuoted): \(error)")
        }

        let wrapped = WrappedPointer(pointer: pointer, oid: entry.oid, name: file)
        do {
            try await single.runToPath(wrapped, to: targetURL, displayPath: targetURL.path)
        } catch {
            throw LFSFailure("Error checking out \(entry.oid) to \(targetURL.path.goQuoted): \(error)")
        }
        await single.close()
        return LFSCommandResult(stderr: single.stderr)
    }

    /// `lfs.NewCurrentToRepoPatternConverter`: converts cwd-relative globs or
    /// file paths to repository-root-relative wildmatch patterns.
    static func rootedPaths(
        _ arguments: [String], workingDirectory: URL, cwd: URL
    ) async throws -> [String] {
        let repoRoot = LFSRepositoryPaths.canonical(workingDirectory.path)
        let currentDir = LFSRepositoryPaths.canonical(cwd.path)
        let passthrough = repoRoot == currentDir
        var result: [String] = []
        for arg in arguments {
            var pattern = passthrough
                ? arg
                : convertToRepoRelative(arg, repoRoot: repoRoot, currentDir: currentDir)
            let statURL = URL(fileURLWithPath: arg, relativeTo: cwd)
            if (try? await Shell.authorize(statURL)) != nil {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: statURL.path, isDirectory: &isDir), isDir.boolValue {
                    pattern += "/"
                }
            }
            if pattern.hasPrefix("./") {
                pattern = String(pattern.dropFirst(2))
                if pattern.isEmpty { pattern = "**" }
            }
            result.append(pattern)
        }
        return result
    }

    private static func convertToRepoRelative(
        _ argument: String, repoRoot: String, currentDir: String
    ) -> String {
        let joined: String
        if (argument as NSString).isAbsolutePath {
            joined = LFSRepositoryPaths.canonical(argument)
        } else {
            let base = currentDir.hasSuffix("/") ? currentDir : currentDir + "/"
            joined = base + argument
        }
        return lexicalRelativePath(from: repoRoot, to: joined)
    }

    private static func lexicalRelativePath(from base: String, to target: String) -> String {
        let baseParts = cleanedPathParts(base)
        let targetParts = cleanedPathParts(target)
        var common = 0
        while common < baseParts.count && common < targetParts.count
            && baseParts[common] == targetParts[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: baseParts.count - common)
        let remainder = targetParts[common...]
        let combined = ups + remainder
        return combined.isEmpty ? "." : combined.joined(separator: "/")
    }

    private static func cleanedPathParts(_ path: String) -> [String] {
        var stack: [String] = []
        for component in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(String(component))
            }
        }
        return stack
    }

    private static func absoluteTargetURL(_ path: String, relativeTo cwd: URL) -> URL {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
    }
}
