import Foundation

/// Only the manifest's configured names; no adapters are constructed or run.
enum LFSTransferListing {
    static func names(_ config: LFSConfiguration, upload: Bool) -> String {
        if config.boolean("lfs.basictransfersonly") { return "basic" }
        var names: Set<String> = ["basic", "lfs-standalone-file", "ssh"]
        // The tus adapter is upload-only.
        if upload && config.boolean("lfs.tustransfers") { names.insert("tus") }
        let pattern = #"lfs.customtransfer.([^.]+).path"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for entry in config.entries {
            let range = NSRange(entry.key.startIndex..., in: entry.key)
            guard let match = regex?.firstMatch(in: entry.key, range: range),
                  let capture = Range(match.range(at: 1), in: entry.key) else { continue }
            let name = String(entry.key[capture])
            let raw = config.get("lfs.customtransfer.\(name).direction") ?? ""
            let direction = raw.isEmpty ? "both" : raw.lowercased()
            if direction == "both" || direction == (upload ? "upload" : "download") { names.insert(name) }
        }
        return names.sorted().joined(separator: ",")
    }
}
