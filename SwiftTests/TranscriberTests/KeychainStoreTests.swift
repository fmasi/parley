import Testing
import Foundation
@testable import TranscriberCore

/// In-memory fake of `KeychainStoring`, shared by every test file that needs a Keychain
/// stand-in (#48). Never touches the real macOS Keychain — `SecItem*` calls are slow, need
/// entitlements to stay silent, and can raise an OS prompt outside a signed/sandboxed context,
/// none of which belongs in a unit test. Internal (default) access, so it's visible to every
/// file in this test target without a shared helpers file.
final class FakeKeychainStore: KeychainStoring, @unchecked Sendable {
    private(set) var storage: [String: String] = [:]
    /// Call counts, for tests that care whether a lookup/write actually happened.
    private(set) var setCallCount = 0
    private(set) var getCallCount = 0
    private(set) var deleteCallCount = 0

    /// When set, `set` throws this instead of storing — simulates a Keychain write failure so
    /// callers (e.g. `ConfigManager`'s migration) can be tested on that path.
    var setError: Error?

    private static func key(_ service: String, _ account: String) -> String { "\(service)\u{0}\(account)" }

    func set(_ value: String, service: String, account: String) throws {
        setCallCount += 1
        if let setError { throw setError }
        storage[Self.key(service, account)] = value
    }

    func get(service: String, account: String) throws -> String? {
        getCallCount += 1
        return storage[Self.key(service, account)]
    }

    func delete(service: String, account: String) throws {
        deleteCallCount += 1
        storage.removeValue(forKey: Self.key(service, account))
    }
}

struct KeychainStoreTests {

    // MARK: - FakeKeychainStore basics (sanity-checks the fake itself)

    @Test func fakeStoreRoundTrips() throws {
        let store = FakeKeychainStore()
        try store.set("sk-test", service: "svc", account: "acct")
        #expect(try store.get(service: "svc", account: "acct") == "sk-test")
    }

    @Test func fakeStoreGetMissingReturnsNil() throws {
        let store = FakeKeychainStore()
        #expect(try store.get(service: "svc", account: "acct") == nil)
    }

    @Test func fakeStoreSetOverwrites() throws {
        let store = FakeKeychainStore()
        try store.set("first", service: "svc", account: "acct")
        try store.set("second", service: "svc", account: "acct")
        #expect(try store.get(service: "svc", account: "acct") == "second")
    }

    @Test func fakeStoreDeleteRemovesItem() throws {
        let store = FakeKeychainStore()
        try store.set("sk-test", service: "svc", account: "acct")
        try store.delete(service: "svc", account: "acct")
        #expect(try store.get(service: "svc", account: "acct") == nil)
    }

    @Test func fakeStoreDeleteOfMissingItemDoesNotThrow() throws {
        let store = FakeKeychainStore()
        try store.delete(service: "svc", account: "acct")
    }

    @Test func fakeStoreScopesByServiceAndAccount() throws {
        let store = FakeKeychainStore()
        try store.set("a-key", service: "svc-a", account: "acct")
        try store.set("b-key", service: "svc-b", account: "acct")
        #expect(try store.get(service: "svc-a", account: "acct") == "a-key")
        #expect(try store.get(service: "svc-b", account: "acct") == "b-key")
    }

    // MARK: - SummaryAPIKeyStore facade

    @Test func summaryAPIKeyStoreLoadReturnsEmptyWhenNothingStored() {
        let store = FakeKeychainStore()
        #expect(SummaryAPIKeyStore.load(keychain: store) == "")
    }

    @Test func summaryAPIKeyStoreSaveThenLoadRoundTrips() {
        let store = FakeKeychainStore()
        SummaryAPIKeyStore.save("sk-real-key", keychain: store)
        #expect(SummaryAPIKeyStore.load(keychain: store) == "sk-real-key")
    }

    @Test func summaryAPIKeyStoreSaveEmptyStringDeletesExistingKey() {
        let store = FakeKeychainStore()
        SummaryAPIKeyStore.save("sk-real-key", keychain: store)
        #expect(store.storage.isEmpty == false)
        SummaryAPIKeyStore.save("", keychain: store)
        #expect(SummaryAPIKeyStore.load(keychain: store) == "")
        #expect(store.storage.isEmpty)
    }

    @Test func summaryAPIKeyStoreUsesAFixedServiceAndAccount() {
        // Config.summary holds at most one active provider config at a time, so a single fixed
        // (service, account) pair is correct — pin it so a future change to per-provider keys is
        // a deliberate decision, not an accidental rename.
        #expect(SummaryAPIKeyStore.service == "eu.fmasi.parley.summary-api-key")
        #expect(SummaryAPIKeyStore.account == "default")
    }

    @Test func summaryAPIKeyStoreLoadToleratesUnderlyingFailure() {
        struct AlwaysThrows: KeychainStoring, @unchecked Sendable {
            func set(_ value: String, service: String, account: String) throws { throw KeychainError.unexpectedStatus(-1) }
            func get(service: String, account: String) throws -> String? { throw KeychainError.unexpectedStatus(-1) }
            func delete(service: String, account: String) throws { throw KeychainError.unexpectedStatus(-1) }
        }
        // `load`/`save` are best-effort at their call sites (Settings, CLI) — a Keychain failure
        // must not crash or throw out of these, only surface as "no key".
        #expect(SummaryAPIKeyStore.load(keychain: AlwaysThrows()) == "")
        SummaryAPIKeyStore.save("sk-x", keychain: AlwaysThrows())  // must not throw/crash
    }
}
