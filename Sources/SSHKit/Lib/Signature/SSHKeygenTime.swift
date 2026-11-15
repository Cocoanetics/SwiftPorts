import Foundation

/// `misc.c`'s absolute time syntax: date, minute or second precision, optionally UTC.
public enum SSHKeygenTime {
    public static func parse(_ text: String) throws -> Date {
        let suffix = text.uppercased()
        let utc = suffix.hasSuffix("Z") || suffix.hasSuffix("UTC")
        let digits = String(text.dropLast(suffix.hasSuffix("UTC") ? 3 : (utc ? 1 : 0)))
        switch digits.count {
        case 8, 12, 14: break
        default: throw SSHKeygenError("Invalid absolute time")
        }
        guard digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw SSHKeygenError("Invalid absolute time")
        }
        let chars = Array(digits)
        func number(_ start: Int, _ count: Int) -> Int {
            start + count <= chars.count ? Int(String(chars[start..<(start + count)])) ?? 0 : 0
        }
        let year = number(0, 4), month = number(4, 2), day = number(6, 2)
        let hour = number(8, 2), minute = number(10, 2), second = number(12, 2)
        guard (1...12).contains(month), (1...31).contains(day), hour <= 23, minute <= 59, second <= 60 else {
            throw SSHKeygenError("Invalid absolute time")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc ? TimeZone(secondsFromGMT: 0)! : .current
        // strptime validates component ranges; mktime/timegm then normalize dates such as February 30.
        guard let date = calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)),
              date.timeIntervalSince1970 != 0 else { throw SSHKeygenError("Invalid absolute time") }
        return date
    }
}
