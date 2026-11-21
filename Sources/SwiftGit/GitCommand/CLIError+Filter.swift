import SwiftGit

extension CLIError {
    init(filter error: GitFilterError, clone: Bool = false) {
        // convert.c quotes the clean driver's name, but not the smudge driver's.
        let driver = error.direction == .clean ? "'\(error.driver)'" : error.driver
        var lines = ["fatal: \(error.path): \(error.direction) filter \(driver) failed"]
        if clone {
            lines += [
                "warning: Clone succeeded, but checkout failed.",
                "You can inspect what was checked out with 'git status'",
                "and retry with 'git restore --source=HEAD :/'", ""
            ]
        }
        self.init(lines: lines, exitCode: 128)
    }
}
