#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import Testing

@Suite("Independent upload server executable lookup")
struct LFSPlainUploadServerTests {
    @Test("Windows Path is case-insensitive; Unix PATH is case-sensitive")
    func pathLookup() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = directory.appendingPathComponent("python.exe")
        let exists: (URL) -> Bool = { $0 == executable }
        #expect(LFSPlainUploadServer.pythonExecutable(
            environment: ["Path": directory.path], windows: true, isExecutable: exists)
                == executable)
        #expect(LFSPlainUploadServer.pythonExecutable(
            environment: ["pAtH": directory.path], windows: true, isExecutable: exists)
                == executable)
        #expect(LFSPlainUploadServer.pythonExecutable(
            environment: ["Path": directory.path], windows: false, isExecutable: exists) == nil)
    }
}
#endif
