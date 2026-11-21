import Foundation
import ShellKit

extension LFSConfiguration {
    /// `strconv.Atoi`: decimal ASCII digits, optional sign, no whitespace or suffix.
    static func integer(_ value: String?, fallback: Int) -> Int {
        guard let value, !value.isEmpty else { return fallback }
        let digits = value.first == "+" || value.first == "-" ? value.dropFirst() : value[...]
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return fallback }
        return Int(value) ?? fallback
    }

    func integer(_ key: String, fallback: Int) -> Int {
        Self.integer(get(key), fallback: fallback)
    }

    func boolean(_ key: String, fallback: Bool = false) -> Bool {
        Self.bool(get(key), fallback: fallback)
    }

    var skipDownloadErrors: Bool {
        Self.bool(Shell.env("GIT_LFS_SKIP_DOWNLOAD_ERRORS"), fallback: false)
            || boolean("lfs.skipdownloaderrors")
    }

    /// `tools.CleanPaths` trims whitespace and one trailing slash per pattern.
    func fetchPaths(_ key: String) -> [String] {
        Self.cleanPaths(get(key) ?? "")
    }

    /// `tools.CleanPaths(value, ",")`.
    static func cleanPaths(_ value: String) -> [String] {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        return value.components(separatedBy: ",").map {
            var path = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasSuffix("/") || path.hasSuffix("\\") { path.removeLast() }
            return path
        }
    }

    /// `readGitConfig` collects extensions even when only a priority is configured.
    var extensionLines: [String] {
        var names: [String] = []
        var priorities: [String: Int] = [:]
        for entry in entries {
            let parts = Self.splitDots(entry.key)
            guard parts.count == 4, parts[0] == "lfs", parts[1] == "extension" else { continue }
            let name = parts[2]
            if priorities[name] == nil { names.append(name); priorities[name] = 0 }
            if parts[3] == "priority", Self.integer(entry.value, fallback: -1) >= 0 {
                priorities[name] = Self.integer(entry.value, fallback: 0)
            }
        }
        return names.map { "Extension[\(priorities[$0] ?? 0)]=\($0)" }
    }
}
