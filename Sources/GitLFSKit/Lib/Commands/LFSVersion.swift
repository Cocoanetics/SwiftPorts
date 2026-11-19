/// The upstream compatibility version, with the port's own runtime identity.
public enum LFSVersion {
    public static var string: String {
        "git-lfs/3.7.1 (SwiftPorts; \(operatingSystem) \(architecture); swift \(runtime))"
    }

    private static var operatingSystem: String {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        "darwin"
        #elseif os(Windows)
        "windows"
        #elseif os(Android)
        "android"
        #elseif os(Linux)
        "linux"
        #else
        "unknown"
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "amd64"
        #elseif arch(i386)
        "386"
        #elseif arch(arm)
        "arm"
        #else
        "unknown"
        #endif
    }

    private static var runtime: String {
        #if swift(>=6.4)
        "6.4"
        #elseif swift(>=6.3)
        "6.3"
        #elseif swift(>=6.2)
        "6.2"
        #else
        "6.1"
        #endif
    }
}
