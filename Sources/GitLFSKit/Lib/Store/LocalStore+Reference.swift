import Foundation
import ShellKit
#if os(Windows)
import WinSDK
#endif

extension LocalStore {
    /// git-lfs 3.7.1 `lfs.LinkOrCopyFromReference`: try reference objects
    /// before scheduling a download, accepting only files of the expected size.
    func linkOrCopyFromReference(_ oid: String, size: Int64, directories: [String]) async throws {
        if try await objectExists(oid, size: size) { return }
        let destination = try await objectPath(oid)
        try await Shell.authorize(destination)
        for directory in directories {
            let source = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(String(oid.prefix(2)), isDirectory: true)
                .appendingPathComponent(String(oid.dropFirst(2).prefix(2)), isDirectory: true)
                .appendingPathComponent(oid)
            do { try await Shell.authorize(source) } catch { continue }
            guard Self.isObject(at: source, size: size) else { continue }
            do {
                try await linkOrCopy(from: source, to: destination)
                return
            } catch { continue }
        }
    }

    /// `lfs.LinkOrCopy` / `CopyFileContents`: hard-link first, then stream to
    /// a temporary file and rename over the destination if linking fails.
    private func linkOrCopy(from source: URL, to destination: URL) async throws {
        if source == destination { return }
        #if os(Windows)
        let linked = source.path.withCString(encodedAs: UTF16.self) { existing in
            destination.path.withCString(encodedAs: UTF16.self) { name in
                CreateHardLinkW(name, existing, nil)
            }
        }
        if linked { return }
        #else
        do {
            try FileManager.default.linkItem(at: source, to: destination)
            return
        } catch { /* Fall back to copying, including when the destination exists. */ }
        #endif
        let temporary = try await makeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: temporary)
        defer { try? writer.close() }
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.close()
        try renameReplacing(temporary.path, destination.path)
    }
}
