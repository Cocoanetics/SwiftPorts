import Foundation

/// `misc.c`'s absolute time syntax: date, minute or second precision, optionally UTC.
public enum SSHKeygenTime {
    public static func parse(_ text: String) throws -> Date {
        let utc = text.hasSuffix("Z") || text.hasSuffix("z")
        let digits = utc ? String(text.dropLast()) : text
        let format: String
        switch digits.count {
        case 8: format = "yyyyMMdd"
        case 12: format = "yyyyMMddHHmm"
        case 14: format = "yyyyMMddHHmmss"
        default: throw SSHKeygenError("Invalid absolute time")
        }
        guard digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw SSHKeygenError("Invalid absolute time")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc ? TimeZone(secondsFromGMT: 0) : .current
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: digits), formatter.string(from: date) == digits,
              date.timeIntervalSince1970 > 0 else { throw SSHKeygenError("Invalid absolute time") }
        return date
    }
}
