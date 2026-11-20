import Foundation
import ShellKit

extension LsFilesOptions {
    func render(
        _ pointers: [WrappedPointer], repo: LFSRepository, store: LocalStore,
        deduplicate: Bool,
        seen: inout Set<[UInt8]>, items: inout [LsFilesObject], output: inout String
    ) async throws {
        for entry in pointers {
            let pointer = entry.pointer
            guard pointer.size != 0 else { continue }
            let pathBytes = Array(entry.name.utf8)
            if deduplicate && !seen.insert(pathBytes).inserted { continue }
            let checkout = try await fileExistsOfSize(entry, repo: repo)
            if debug || json {
                let downloaded = try await store.objectExists(pointer.oid, size: pointer.size)
                if debug {
                    output += "filepath: \(entry.name)\n    size: \(pointer.size)\ncheckout: \(checkout)\n"
                        + "download: \(downloaded)\n     oid: \(pointer.oidType) \(pointer.oid)\n"
                        + " version: \(pointer.version)\n\n"
                } else {
                    items.append(LsFilesObject(name: entry.name, size: pointer.size, checkout: checkout,
                                               downloaded: downloaded, oidType: pointer.oidType,
                                               oid: pointer.oid, version: pointer.version))
                }
            } else {
                var fields = nameOnly ? [entry.name]
                    : [String(pointer.oid.prefix(long ? 64 : 10)), checkout ? "*" : "-", entry.name]
                if size { fields.append("(\(ByteFormat.formatBytes(UInt64(pointer.size))))") }
                output += fields.joined(separator: " ") + "\n"
            }
        }
    }

    private func fileExistsOfSize(_ entry: WrappedPointer, repo: LFSRepository) async throws -> Bool {
        let path = (repo.workingDirectory ?? Shell.currentDirectory).appendingPathComponent(entry.name)
        try await Shell.authorize(path)
        // os.Stat follows symlinks and compares only size, even for directories.
        let target = path.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path) else { return false }
        return (attributes[.size] as? NSNumber)?.int64Value == entry.pointer.size
    }
}
