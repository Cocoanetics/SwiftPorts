import Foundation

/// git-lfs 3.7.1 `tools/humanize.FormatBytes` (decimal units). Sizes of an
/// exabyte or more stay in PB, where Go would index past its unit table.
enum ByteFormat {
    private static let suffixes = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func formatBytes(_ size: UInt64) -> String {
        let exponent = size == 0 ? 0 : min(floor(log(Double(size)) / log(1000)), Double(suffixes.count - 1))
        return formatBytesUnit(size, unit: pow(1000, exponent)) + " " + suffixes[Int(exponent)]
    }

    /// `humanize.FormatByteRate(s, time.Second)`.
    static func formatByteRate(_ bytesPerSecond: UInt64) -> String {
        let rate = Double(bytesPerSecond)
        var exponent = 0.0
        if rate != 0 {
            exponent = floor(log(rate) / log(1000))
            if exponent <= 0 { exponent = 0 }
            exponent = min(exponent, Double(suffixes.count - 1))
        }
        // `Double(UInt64.max)` rounds up to 2^64, which UInt64 can't hold.
        let rounded = ceil(rate) >= 18_446_744_073_709_551_616 ? UInt64.max : UInt64(ceil(rate))
        return formatBytesUnit(rounded, unit: pow(1000, exponent)) + " " + suffixes[Int(exponent)] + "/s"
    }

    /// `humanize.FormatBytesUnit`: the quantity in `unit`, to the nearest tenth.
    private static func formatBytesUnit(_ size: UInt64, unit: Double) -> String {
        let rounded = size < 10 ? Double(size) : floor(Double(size) / unit * 10 + 0.5) / 10
        let format = rounded < 10 && unit > 1 ? "%.1f" : "%.0f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
}
