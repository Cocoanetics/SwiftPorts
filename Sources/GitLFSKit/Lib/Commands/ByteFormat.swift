import Foundation

/// git-lfs 3.7.1 `tools/humanize.FormatBytes` (decimal units).
enum ByteFormat {
    static func formatBytes(_ size: UInt64) -> String {
        let exponent = size == 0 ? 0 : floor(log(Double(size)) / log(1000))
        let unit = pow(1000, exponent)
        let suffix = ["B", "KB", "MB", "GB", "TB", "PB"][Int(exponent)]
        let rounded = size < 10 ? Double(size) : floor(Double(size) / unit * 10 + 0.5) / 10
        let format = rounded < 10 && unit > 1 ? "%.1f" : "%.0f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), rounded) + " " + suffix
    }
}
