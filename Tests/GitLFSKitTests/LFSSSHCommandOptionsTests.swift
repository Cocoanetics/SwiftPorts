import Foundation
import Testing
import SSHKit
@testable import GitLFSKit

@Suite("LFS SSH command configuration")
struct LFSSSHCommandOptionsTests {
    @Test("GIT_SSH_COMMAND, GIT_SSH, and core.sshCommand precedence")
    func precedence() async throws {
        let host = IsolatedLFSHost()
        try await host.run {
            let fixture = try await LFSFixture.make(host, "ssh-options", config: [
                ("core.sshcommand", "C:/Windows/System32/OpenSSH/SSH.EXE -F '/core config' -p 2000 -l core")])
            let finder = await LFSEndpointFinder(fixture.client)
            let config = finder.configuration
            let core = try LFSSSHCommandOptions(configuration: config, configPath: "default", environment: { _ in nil })
            #expect(core.configPath == "/core config")
            #expect(core.requireConfigFile)
            #expect(core.directives == ["Port 2000", "User core"])
            let gitSSH = try LFSSSHCommandOptions(configuration: config, configPath: "default") {
                $0 == "GIT_SSH" ? "C:\\Windows\\System32\\OpenSSH\\ssh.exe" : nil
            }
            #expect(gitSSH.configPath == "default")
            #expect(gitSSH.directives.isEmpty)
            let env = ["GIT_SSH": "wrapper", "GIT_SSH_COMMAND":
                "C:/Windows/System32/OpenSSH/ssh.exe -p2222 -l git -i '/my key' "
                + "-o 'StrictHostKeyChecking yes' -F '/env config'"]
            let command = try LFSSSHCommandOptions(
                configuration: config, configPath: "default", environment: { env[$0] })
            #expect(command.configPath == "/env config")
            #expect(command.directives == ["Port 2222", "User git", "IdentityFile \"/my key\"",
                                           "StrictHostKeyChecking yes"])
            let resolved = try SSHConfig.parse((command.directives + ["Port 1234", "User url-user"])
                .joined(separator: "\n")).resolve(host: "alias")
            #expect(resolved.port == 2222)
            #expect(resolved.user == "git")
            #expect(resolved.identityFiles == ["/my key"])
            #expect(resolved.strictHostKeyChecking == .yes)
            #expect(throws: LFSClientError.self) {
                try LFSSSHCommandOptions(configuration: config, configPath: "default") {
                    $0 == "GIT_SSH" ? "wrapper" : nil
                }
            }
            #expect(throws: LFSClientError("SSHKit does not support SSH variant: plink")) {
                try LFSSSHCommandOptions(configuration: config, configPath: "default") {
                    $0 == "GIT_SSH_VARIANT" ? "plink" : nil
                }
            }
        }
    }
}
