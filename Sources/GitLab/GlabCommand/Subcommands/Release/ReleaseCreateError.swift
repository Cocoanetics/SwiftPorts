import Foundation

enum ReleaseCreateError: Error, LocalizedError {
    case alreadyExists(tag: String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let tag):
            return "release for tag \"\(tag)\" already exists and --no-update flag was specified"
        }
    }
}
