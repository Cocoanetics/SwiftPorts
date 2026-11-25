import Foundation
import GitKit
import ShellKit

/// The nonfatal diagnostics one run's configs report (a command-line
/// `gitdir:./` condition), each once, in the order they came. GitKit never
/// prints them; ``GitClient/isolatedGated(deferFilterFailures:retryIncludes:cancellation:_:)``
/// does, after the run's last attempt.
final class ConfigDiagnosticSink: @unchecked Sendable {
    private let lock = NSLock()
    private var diagnostics: [ConfigDiagnostic] = []

    func record(_ reported: [ConfigDiagnostic]) {
        lock.withLock {
            for diagnostic in reported where !diagnostics.contains(diagnostic) {
                diagnostics.append(diagnostic)
            }
        }
    }

    /// Writes them to the shell's stderr as git does, `error: ` first.
    func print() {
        let lines = lock.withLock { diagnostics.map { "error: \($0.message)\n" } }
        for line in lines { Shell.current.stderr(line) }
    }
}
