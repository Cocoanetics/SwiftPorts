import Foundation

enum LFSRetryPolicy {
    /// `retryCounter.ReadyTime`, after incrementing the retry count.
    static func delay(count: Int, maximum: Int) -> TimeInterval {
        min(0.25 * pow(2, Double(count - 1)), Double(maximum))
    }

    static func retryAfter(_ result: LFSTransferHTTPResult, now: Date) -> TimeInterval? {
        guard result.status == 429,
              let value = result.response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(value) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
