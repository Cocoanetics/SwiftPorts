import Crypto
import Foundation

extension SSHPublicKey {
    /// OpenSSH's 17×9 drunken-bishop walk (`sshkey_fingerprint_randomart`).
    public var randomArt: String {
        let width = 17, height = 9
        let palette = Array(" .o+=*BOX@%&#/^SE")
        var field = [Int](repeating: 0, count: width * height)
        var x = width / 2, y = height / 2
        for byte in SHA256.hash(data: blob) {
            var value = byte
            for _ in 0..<4 {
                x = min(width - 1, max(0, x + (value & 1 != 0 ? 1 : -1)))
                y = min(height - 1, max(0, y + (value & 2 != 0 ? 1 : -1)))
                field[y * width + x] = min(palette.count - 3, field[y * width + x] + 1)
                value >>= 2
            }
        }
        field[(height / 2) * width + width / 2] = palette.count - 2
        field[y * width + x] = palette.count - 1
        func frame(_ title: String) -> String {
            let label = "[" + title + "]"
            let left = (width - label.count) / 2
            return "+" + String(repeating: "-", count: left) + label
                + String(repeating: "-", count: width - label.count - left) + "+"
        }
        let rows = (0..<height).map { row in
            "|" + String((0..<width).map { palette[field[row * width + $0]] }) + "|"
        }
        return ([frame("\(shortTypeName) \(bits)")] + rows + [frame("SHA256")]).joined(separator: "\n")
    }
}
