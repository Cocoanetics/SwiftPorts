import Foundation

/// git-lfs writes its config warnings to stderr (`fmt.Fprint(os.Stderr, …)`).
enum LFSStandardError {
    static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
