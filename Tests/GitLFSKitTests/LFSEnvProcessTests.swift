#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("LFS env oracle subprocess")
struct LFSEnvProcessTests {
    @Test func workingDirectoryAndEnvironmentOrder() throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        let environment = ["Z_ENV_TEST=first", "A_ENV_TEST=second"]
        let originalDirectory = FileManager.default.currentDirectoryPath
        let directory = try LFSEnvProcess.run(
            "/bin/pwd", [], cwd: host.home, environment: environment, output: host.root)
        #expect(directory.status == 0)
        let reportedDirectory = URL(fileURLWithPath: directory.stdout.trimmingCharacters(in: .newlines))
            .resolvingSymlinksInPath()
        #expect(reportedDirectory.path == host.home.resolvingSymlinksInPath().path)
        #expect(directory.stderr.isEmpty)
        #expect(FileManager.default.currentDirectoryPath == originalDirectory)

        let variables = try LFSEnvProcess.run(
            "/usr/bin/env", [], cwd: host.home, environment: environment, output: host.root)
        #expect(variables.status == 0)
        #expect(variables.stdout == environment.joined(separator: "\n") + "\n")
        #expect(variables.stderr.isEmpty)
    }
}
#endif
