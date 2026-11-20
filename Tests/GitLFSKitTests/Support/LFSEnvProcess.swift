#if os(macOS) || os(Linux)
import Foundation
import Testing
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// env's oracle needs ordered envp; Process.environment is a dictionary.
enum LFSEnvProcess {
    #if os(macOS)
    private typealias Actions = posix_spawn_file_actions_t?
    #else
    private typealias Actions = posix_spawn_file_actions_t
    private typealias AddChdir = @convention(c) (
        UnsafeMutablePointer<posix_spawn_file_actions_t>, UnsafePointer<CChar>
    ) -> Int32
    #endif

    static func run(
        _ executable: String, _ arguments: [String], cwd: URL, environment: [String], output: URL
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let suffix = UUID().uuidString
        let out = output.appendingPathComponent("stdout-" + suffix)
        let err = output.appendingPathComponent("stderr-" + suffix)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: err)
        }
        #if os(macOS)
        var actions: Actions = nil
        #else
        var actions = Actions()
        #endif
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        #if os(Linux)
        // Glibc exports this GNU extension, but Swift's Glibc module doesn't
        // declare it. Resolve the C function without changing the parent's cwd.
        let symbol = try #require(dlsym(nil, "posix_spawn_file_actions_addchdir_np"))
        let addChdir = unsafeBitCast(symbol, to: AddChdir.self)
        try check(cwd.path.withCString { addChdir(&actions, $0) })
        #else
        try check(posix_spawn_file_actions_addchdir_np(&actions, cwd.path))
        #endif
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, out.path, O_WRONLY | O_CREAT, 0o600))
        try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, err.path, O_WRONLY | O_CREAT, 0o600))
        let status = try spawn(executable, arguments, environment, actions: &actions)
        return (try String(contentsOf: out, encoding: .utf8), try String(contentsOf: err, encoding: .utf8), status)
    }

    private static func spawn(
        _ executable: String, _ arguments: [String], _ environment: [String],
        actions: inout Actions
    ) throws -> Int32 {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable, &actions, nil, argv, envp))
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}
#endif
