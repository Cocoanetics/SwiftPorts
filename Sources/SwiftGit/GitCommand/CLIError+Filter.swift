import SwiftGit
import GitLFSKit

extension CLIError {
    init(filter error: GitFilterError, clone: Bool = false) {
        // convert.c quotes the clean driver's name, but not the smudge driver's.
        let driver = error.direction == .clean ? "'\(error.driver)'" : error.driver
        let fatal = "fatal: \(error.path): \(error.direction) filter \(driver) failed"
        var lines = [fatal]
        var status: Int32 = 128
        if let failure = error.underlying as? LFSFilterFailure, let command = failure.processCommand {
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
