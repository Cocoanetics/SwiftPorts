import Foundation

extension Array where Element == UInt8 {
    /// Whether `needle` occurs anywhere in the bytes.
    func contains(subsequence needle: [UInt8]) -> Bool {
        guard needle.count <= count else { return false }
        return (0...(count - needle.count)).contains { self[$0..<$0 + needle.count].elementsEqual(needle) }
    }
}
