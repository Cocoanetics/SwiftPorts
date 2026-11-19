import Foundation
import Crypto
import ShellKit

/// `commands/command_pointer.go`: build, inspect, compare and check pointers.
public struct LFSPointerOptions: Sendable {
    public var file = ""
    public var pointer = ""
    public var stdin = false
    public var check = false
    public var strict = false
    public var noStrict = false

    public init() {}

    public func run() async throws -> LFSCommandResult {
        var result = LFSCommandResult()
        if check { return try await checkPointer() }
        var built: Data?
        if !file.isEmpty {
            do {
                let url = try await authorizedFile(file)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                var size: Int64 = 0
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    hash.update(data: data)
                    size += Int64(data.count)
                }
                let oid = hash.finalize().map { String(format: "%02x", $0) }.joined()
                let text = Pointer(oid: oid, size: size).encoded
                built = Data(text.utf8)
                result.stdout = text
                result.stderr = "Git LFS pointer for \(file)\n\n"
                if !pointer.isEmpty || stdin {
                    result.stderr += "\nGit blob OID: \(blobOID(Data(text.utf8)))\n\n"
                }
            } catch {
                result.fail(lfsFileError(error, path: file), status: 1)
                return result
            }
        }
        if !pointer.isEmpty || stdin {
            if !pointer.isEmpty && stdin {
                result.fail("cannot read from STDIN and --pointer", status: 1)
                return result
            }
            let data: Data
            do {
                if stdin {
                    data = await readPointerInput()
                } else {
                    data = try await readPointerFile(pointer)
                }
            } catch {
                result.fail(lfsFileError(error, path: pointer), status: 1)
                return result
            }
            // DecodePointer reads at most BlobSizeCutoff bytes through its tee.
            let compared = Data(data.prefix(Pointer.blobSizeCutoff))
            result.stderr += "Pointer from \(stdin ? "STDIN" : pointer)\n\n"
            do {
                _ = try Pointer.decode(compared)
            } catch {
                result.fail(String(describing: error), status: 1)
                return result
            }
            result.stderr += String(decoding: compared, as: UTF8.self)
            if let built {
                result.stderr += "\nGit blob OID: \(blobOID(compared))\n"
                if blobOID(built) != blobOID(compared) {
                    result.fail("\nPointers do not match", status: 1)
                }
            }
        } else if file.isEmpty {
            result.fail("Nothing to do!", status: 1)
        }
        return result
    }

    private func checkPointer() async throws -> LFSCommandResult {
        if strict && noStrict {
            return LFSCommandResult(stderr: "Cannot combine --strict with --no-strict\n", status: 2)
        }
        if !pointer.isEmpty {
            return LFSCommandResult(stderr: "Cannot combine --check with --compare\n", status: 2)
        }
        if !file.isEmpty && stdin {
            return LFSCommandResult(stderr: "With --check, --file cannot be combined with --stdin\n", status: 2)
        }
        if file.isEmpty && !stdin {
            return LFSCommandResult(stderr: "Must specify either --file or --stdin with --compare\n", status: 2)
        }
        let data: Data
        do {
            if stdin {
                data = await readPointerInput()
            } else {
                data = try await readPointerFile(file)
            }
        } catch {
            return LFSCommandResult(stderr: lfsFileError(error, path: file) + "\n", status: 2)
        }
        guard let decoded = try? Pointer.decode(data) else { return LFSCommandResult(status: 1) }
        return LFSCommandResult(status: strict && !decoded.canonical ? 2 : 0)
    }

    private func authorizedFile(_ path: String) async throws -> URL {
        let url = URL(fileURLWithPath: path, relativeTo: Shell.currentDirectory)
        try await Shell.authorize(url)
        return url
    }

    private func readPointerFile(_ path: String) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: await authorizedFile(path))
        defer { try? handle.close() }
        return try handle.read(upToCount: Pointer.blobSizeCutoff) ?? Data()
    }

    private func readPointerInput() async -> Data {
        var data = Data()
        for await chunk in Shell.current.stdin.bytes {
            data.append(chunk.prefix(Pointer.blobSizeCutoff - data.count))
            if data.count == Pointer.blobSizeCutoff { break }
        }
        return data
    }

    private func blobOID(_ data: Data) -> String {
        let header = Data("blob \(data.count)\0".utf8)
        return Insecure.SHA1.hash(data: header + data).map { String(format: "%02x", $0) }.joined()
    }

}
