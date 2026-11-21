#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import Testing

@Suite("Independent upload server executable lookup")
struct LFSPlainUploadServerTests {
    @Test("Windows uses pythonLocation before the Python 3 launcher, never python on PATH")
    func pathLookup() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = directory.appendingPathComponent("python.exe")
        let launcher = directory.appendingPathComponent("py.exe")
        let exists: (URL) -> Bool = { $0 == executable || $0 == launcher }
        let configured = LFSPlainUploadServer.pythonCommand(
            environment: ["PYTHONLOCATION": directory.path, "Path": directory.path],
            windows: true, isExecutable: exists)
        #expect(configured?.executable == executable)
        #expect(configured?.arguments == [])
        let fallback = LFSPlainUploadServer.pythonCommand(
            environment: ["pAtH": directory.path], windows: true, isExecutable: exists)
        #expect(fallback?.executable == launcher)
        #expect(fallback?.arguments == ["-3"])
        #expect(LFSPlainUploadServer.pythonCommand(
            environment: ["Path": directory.path], windows: true,
            isExecutable: { $0 == executable }) == nil)
        #expect(LFSPlainUploadServer.pythonCommand(
            environment: [:], windows: true, isExecutable: exists) == nil)
    }

    @Test("Unix requires the case-sensitive PATH and Python 3")
    func unixLookup() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = directory.appendingPathComponent("python3")
        let exists: (URL) -> Bool = { $0 == executable }
        #expect(LFSPlainUploadServer.pythonCommand(
            environment: ["Path": directory.path], windows: false, isExecutable: exists) == nil)
        let command = LFSPlainUploadServer.pythonCommand(
            environment: ["PATH": directory.path], windows: false, isExecutable: exists)
        #expect(command?.executable == executable)
        #expect(command?.arguments == [])
    }
}
#endif
