import Foundation
import ShellKit
import SwiftGit

extension StatusOptions {
    func renderHuman(_ index: StatusIndex, client: GitClient, root: URL, output: inout String) async throws {
        let scanner = PointerScanner(client: client)
        let cwd = LFSRepositoryPaths.canonical(Shell.currentDirectory.path)
        let root = URL(fileURLWithPath: LFSRepositoryPaths.canonical(root.path))
        output += "\nObjects to be committed:\n\n"
        for entry in index.staged {
            let source = Self.relativize(cwd, root.appendingPathComponent(entry.sourcePath).path)
            let name: String
            if entry.status == "R" || entry.status == "C" {
                let destination = Self.relativize(cwd, root.appendingPathComponent(entry.destinationPath).path)
                name = source + " -> " + destination
            } else {
                name = source
            }
            let info = try await formatBlobInfo(entry, scanner: scanner, root: root)
            output += "\t\(name) (\(info))\n"
        }
        output += "\nObjects not staged for commit:\n\n"
        for entry in index.unstaged {
            let source = Self.relativize(cwd, root.appendingPathComponent(entry.sourcePath).path)
            let info = try await formatBlobInfo(entry, scanner: scanner, root: root)
            output += "\t\(source) (\(info))\n"
        }
        output += "\n"
    }

    static func renderPorcelain(_ index: StatusIndex) -> String {
        var seen = Set<[UInt8]>()
        var output = ""
        for entry in index.unstaged + index.staged {
            let name = entry.destinationPath.isEmpty ? entry.sourcePath : entry.destinationPath
            guard seen.insert(Array(name.utf8)).inserted else { continue }
            switch entry.status {
            case "R", "C": output += "\(entry.status)  \(entry.sourcePath) -> \(entry.destinationPath)\n"
            case "M": output += " M \(entry.sourcePath)\n"
            default: output += "\(entry.status)  \(entry.sourcePath)\n"
            }
        }
        return output
    }

    func renderJSON(_ index: StatusIndex, client: GitClient, root: URL) async throws -> String {
        var status = JSONStatus()
        let scanner = PointerScanner(client: client)
        for entry in index.unstaged + index.staged {
            guard case .lfs = try await blobInfoFrom(entry, scanner: scanner, root: root) else { continue }
            let moved = entry.status == "R" || entry.status == "C"
            let name = moved ? entry.destinationPath : entry.sourcePath
            status.files[Data(name.utf8)] = JSONStatusEntry(
                status: String(entry.status), from: moved ? entry.sourcePath : nil)
        }
        return try status.json() + "\n"
    }

    /// Upstream's `relativize` compares slash-separated paths without quoting them.
    private static func relativize(_ from: String, _ to: String) -> String {
        #if os(Windows)
        let from = from.replacingOccurrences(of: "\\", with: "/")
        let to = to.replacingOccurrences(of: "\\", with: "/")
        #endif
        let source = from.components(separatedBy: "/")
        let destination = to.components(separatedBy: "/")
        var common = 0
        while common < min(source.count, destination.count)
            && source[common].utf8.elementsEqual(destination[common].utf8) {
            common += 1
        }
        return String(repeating: "../", count: source.count - common)
            + destination.dropFirst(common).joined(separator: "/")
    }
}
