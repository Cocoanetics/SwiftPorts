import Foundation
import ShellKit
import SwiftGit

extension Hook {
    /// The pre-push hook `git push` would run (git's `find_hook`), when it
    /// is git-lfs's: `pre-push` in the hooks directory `git lfs install`
    /// writes to, executable (on Windows, there at all), and a script one of
    /// whose lines, `#` comments aside, runs `git lfs pre-push`,
    /// `git-lfs pre-push`, or the historical `git lfs push --stdin`. The
    /// script is read, never run; `nil` for any other hook, or none.
    public static func lfsPrePush(_ client: GitClient) async -> Hook? {
        guard let repository = try? await LFSRepository.open(client, verifyFormat: false),
              let directory = try? await repository.hookDirectory(client) else { return nil }
        let hook = Hook(type: "pre-push", directory: directory)
        let path = hook.path.path
        guard (try? await Shell.authorize(hook.path)) != nil else { return nil }
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

    /// Whether `script` has a line, other than a `#` comment, that runs
    /// git-lfs's pre-push.
    static func runsLFSPrePush(_ script: String) -> Bool {
        script.split(whereSeparator: \.isNewline).contains { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            return ["git lfs pre-push", "git-lfs pre-push", "git lfs push --stdin"].contains { line.contains($0) }
        }
    }
}
