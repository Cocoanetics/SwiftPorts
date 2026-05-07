import Foundation
import Sandbox
import GitHub

/// Output sinks for subcommand printing. Tiny abstraction so tests
/// can capture stdout/stderr without intercepting `FileHandle`.
public protocol Printer: Sendable {
    func print(_ string: String)
    func error(_ string: String)
}

public struct StandardPrinter: Printer {
    public init() {}
    public func print(_ string: String) {
        Stdio.stdout.write(Data((string + "\n").utf8))
    }
    public func error(_ string: String) {
        Stdio.stderr.write(Data((string + "\n").utf8))
    }
}

/// Pretty-print arbitrary JSON `Data` to a string.
public enum JSONPretty {
    public static func string(from data: Data) -> String {
        guard let any = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: any,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return string
    }
}

/// Encode a `Codable` value into pretty JSON text using
/// the GitHub-flavoured encoder (snake_case, ISO 8601).
public enum CodableOutput {
    public static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder.gitHub()
        encoder.outputFormatting.formUnion([.prettyPrinted, .sortedKeys])
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
