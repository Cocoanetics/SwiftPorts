import SwiftGit
import GitLFSKit

extension CLIError {
    init(filter error: GitFilterError, clone: Bool = false) {
        self.init(driver: error.driver, path: error.path, direction: error.direction,
                  failure: error.underlying as? LFSFilterFailure, clone: clone)
    }

    init(filter failure: LFSFilterFailure, clone: Bool = false) {
        self.init(driver: "lfs", path: failure.path, direction: .smudge, failure: failure, clone: clone)
    }

    private init(driver: String, path: String, direction: GitFilterDirection,
                 failure: LFSFilterFailure?, clone: Bool) {
        // convert.c quotes the clean driver's name, but not the smudge driver's.
        let driver = direction == .clean ? "'\(driver)'" : driver
        let fatal = "fatal: \(path): \(direction) filter \(driver) failed"
        var lines = [fatal]
        var status: Int32 = 128
        if let failure, let command = failure.processCommand {
            lines = ["error: external filter '\(command)' failed"]
            if failure.required {
                lines.append(fatal)
            } else {
                lines.append("error: external filter '\(command)' is not available anymore "
                    + "although not all paths have been filtered")
                if clone { lines.append("fatal: unable to checkout working tree") }
                else { status = 1 }
            }
        }
        if clone {
            lines += [
                "warning: Clone succeeded, but checkout failed.",
                "You can inspect what was checked out with 'git status'",
                "and retry with 'git restore --source=HEAD :/'", ""
            ]
        }
        self.init(lines: lines, exitCode: status)
    }
}
