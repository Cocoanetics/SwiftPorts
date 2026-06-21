import Foundation
import Testing
@testable import ForgeKit

/// The behavioral contract every `SecretStore` backend must satisfy.
/// Run against each concrete backend so they can't drift. Uses
/// per-call random service names so it's safe against a real OS keyring.
private func assertConforms(_ store: any SecretStore) async throws {
    let svc = "com.swiftports.test.\(UUID().uuidString)"
    let svc2 = "com.swiftports.test.\(UUID().uuidString)"

    // round-trip
    try await store.set(service: svc, account: "github.com", secret: "abc")
    #expect(try await store.get(service: svc, account: "github.com") == "abc")

    // missing → nil (not an error)
    #expect(try await store.get(service: svc, account: "absent") == nil)

    // overwrite
    try await store.set(service: svc, account: "github.com", secret: "def")
    #expect(try await store.get(service: svc, account: "github.com") == "def")

    // separates by both service AND account
    try await store.set(service: svc, account: "gitlab.com", secret: "ghi")
    try await store.set(service: svc2, account: "github.com", secret: "jkl")
    #expect(try await store.get(service: svc, account: "github.com") == "def")
    #expect(try await store.get(service: svc, account: "gitlab.com") == "ghi")
    #expect(try await store.get(service: svc2, account: "github.com") == "jkl")

    // delete, then deleting again is a no-op (must not throw)
    try await store.delete(service: svc, account: "github.com")
    #expect(try await store.get(service: svc, account: "github.com") == nil)
    try await store.delete(service: svc, account: "github.com")

    // cleanup
    try await store.delete(service: svc, account: "gitlab.com")
    try await store.delete(service: svc2, account: "github.com")
}

@Suite struct SecretStoreConformanceTests {
    @Test func inMemoryConforms() async throws {
        try await assertConforms(InMemorySecretStore())
    }

    @Test func fileStoreConforms() async throws {
        let dir = FileSecretStoreTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await assertConforms(FileSecretStore(directory: dir))
    }
}

@Suite struct FileSecretStoreTests {
    static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftports-secrets-\(UUID().uuidString)", isDirectory: true)
    }

    /// The whole point of this PR: a value written by one process is
    /// visible to the next — impossible with `InMemorySecretStore`.
    @Test func persistsAcrossInstances() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await FileSecretStore(directory: dir)
            .set(service: "s", account: "a", secret: "persisted")
        let fresh = FileSecretStore(directory: dir)   // distinct instance
        #expect(try await fresh.get(service: "s", account: "a") == "persisted")
    }

    #if !os(Windows)
    @Test func fileIsOwnerOnly() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FileSecretStore(directory: dir)
        try await store.set(service: "s", account: "a", secret: "x")

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    #endif

    @Test func toleratesCorruptFile() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = FileSecretStore(directory: dir)
        try Data("this is not json".utf8).write(to: store.fileURL)

        // Corrupt file reads as empty rather than throwing…
        #expect(try await store.get(service: "s", account: "a") == nil)
        // …and a subsequent write recovers the store.
        try await store.set(service: "s", account: "a", secret: "recovered")
        #expect(try await store.get(service: "s", account: "a") == "recovered")
    }
}

#if os(Linux)
/// Exercises the real libsecret backend. Opt-in (needs an unlocked
/// Secret Service / keyring daemon, which CI lacks by default) — the
/// Docker verification runs it under `dbus-run-session` + gnome-keyring.
@Suite(
    .disabled(if: ProcessInfo.processInfo.environment["SWIFTPORTS_LIBSECRET_TESTS"] == nil,
              "Set SWIFTPORTS_LIBSECRET_TESTS=1 (needs an unlocked keyring) to exercise libsecret.")
)
struct LibSecretStoreTests {
    @Test func realKeyringConforms() async throws {
        #expect(LibSecretStore.isAvailable)
        try await assertConforms(LibSecretStore())
    }
}
#endif
