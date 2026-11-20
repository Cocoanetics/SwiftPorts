import Foundation
import ShellKit

/// git-lfs writes its config warnings to stderr (`fmt.Fprint(os.Stderr, …)`).
enum LFSStandardError {
    static func write(_ text: String) {
        Shell.current.stderr.write(Data(text.utf8))
    }
}
