import Foundation
import ShellKit
import SwiftGit

extension Hook {
    /// The pre-push hook `git push` would run (git's `find_hook`), when it
    /// is git-lfs's: `pre-push` in the hooks directory `git lfs install`
    /// writes to, executable (on Windows, there at all), and a script one of
    /// whose lines is a command running `git lfs pre-push`,
    /// `git-lfs pre-push`, or the historical `git lfs push --stdin`. The
    /// script is read, never run; `nil` for any other hook, or none. The
    /// sandbox refusing the hook, or the config naming its directory,
    /// throws: the push must not go ahead as if there were no hook.
    public static func lfsPrePush(_ client: GitClient) async throws -> Hook? {
        guard let repository = try? await LFSRepository.open(client, verifyFormat: false) else { return nil }
        let hook = Hook(type: "pre-push", directory: try await repository.hookDirectory(client))
        let path = hook.path.path
        try await Shell.authorize(hook.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        #if !os(Windows)
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        #endif
        guard let data = FileManager.default.contents(atPath: path),
              runsLFSPrePush(String(decoding: data, as: UTF8.self)) else { return nil }
        return hook
    }

    /// Whether a line of `script` is a command, `exec` or not, that runs
    /// git-lfs's pre-push. Text after a `#`, whole line or trailing, is a
    /// comment, and an LFS command inside one runs nothing.
    static func runsLFSPrePush(_ script: String) -> Bool {
        script.split(whereSeparator: \.isNewline).contains { line in
            var command = line.trimmingCharacters(in: .whitespaces)[...]
            if command.hasPrefix("exec ") {
                command = command.dropFirst("exec ".count).drop { $0 == " " || $0 == "\t" }
            }
            return ["git lfs pre-push", "git-lfs pre-push", "git lfs push --stdin"].contains { name in
                guard command.hasPrefix(name) else { return false }
                let rest = command.dropFirst(name.count)
                return rest.first.map { $0 == " " || $0 == "\t" } ?? true
            }
        }
    }
}
