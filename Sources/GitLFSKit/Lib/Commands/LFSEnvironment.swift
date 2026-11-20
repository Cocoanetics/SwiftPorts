import Foundation
import ShellKit
#if canImport(Darwin)
import Darwin.crt_externs
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif os(Android)
import Android
#elseif os(Windows)
import ucrt
#endif

enum LFSEnvironment {
    /// Preserve os.Environ order for inherited names, but take every value from
    /// the active Shell. A virtual-only name follows in the Shell's enumeration.
    static func gitEntries() -> [String] {
        let variables = Shell.current.environment.variables
        var names: [String] = []
        var seen = Set<String>()
        #if canImport(Darwin)
        let block = _NSGetEnviron().pointee
        #elseif os(Windows)
        let block = __p__environ().pointee
        #else
        let block: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = environ
        #endif
        var index = 0
        while let pointer = block?[index] {
            let entry = String(cString: pointer)
            let key = String(entry.prefix(while: { $0 != "=" }))
            if key.hasPrefix("GIT_"), variables[key] != nil, seen.insert(key).inserted { names.append(key) }
            index += 1
        }
        for key in variables.keys where key.hasPrefix("GIT_") && seen.insert(key).inserted { names.append(key) }
        return names.map { "\($0)=\(variables[$0] ?? "")" }
    }
}
