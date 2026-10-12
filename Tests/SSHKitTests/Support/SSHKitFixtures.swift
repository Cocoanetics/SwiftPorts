import Foundation

/// Loads fixture files from `Tests/SSHKitTests/Fixtures/` (real `ssh-keygen`-generated keys and
/// `known_hosts`/`ssh_config` samples — see that directory for how they were produced).
enum SSHKitFixtures {
    static func path(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            fatalError("Fixture \(name) not found. Add it under Tests/SSHKitTests/Fixtures/.")
        }
        return url.path
    }

    static func contents(_ name: String) throws -> String {
        try String(contentsOfFile: Self.path(name), encoding: .utf8)
    }
}
