import Foundation
import Security
import os

/// Errors surfaced by `KeychainStoring` implementations.
public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case unexpectedData
}

/// A small string-secret store, abstracted behind a protocol so call sites — and tests — don't
/// depend on the real macOS Keychain (#48). `SecItem*` calls are slow, need entitlements to stay
/// silent, and can raise an OS prompt outside a signed/sandboxed context — none of that belongs
/// in a unit test. Tests use a fake conforming to this protocol instead of `KeychainStore`
/// (see `SwiftTests/TranscriberTests/KeychainStoreTests.swift`).
public protocol KeychainStoring: Sendable {
    /// Stores `value` under (`service`, `account`), overwriting any existing item.
    func set(_ value: String, service: String, account: String) throws
    /// Returns the stored value, or `nil` if nothing is stored under (`service`, `account`).
    func get(service: String, account: String) throws -> String?
    /// Removes the item at (`service`, `account`). Not an error when nothing was stored.
    func delete(service: String, account: String) throws
}

/// Real macOS Keychain-backed implementation of `KeychainStoring`, via `SecItemAdd` /
/// `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete` against generic-password items
/// scoped by (`service`, `account`).
public final class KeychainStore: KeychainStoring, @unchecked Sendable {
    public static let shared = KeychainStore()

    public init() {}

    public func set(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query = Self.query(service: service, account: account)

        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        switch existing {
        case errSecSuccess:
            // Also (re-)assert kSecAttrAccessible on the update path, not just kSecValueData: if
            // an item for this (service, account) ever existed with a different accessibility
            // (e.g. the Security framework's WhenUnlocked default, from before this code ever
            // ran), updating only the value would leave that stale accessibility in place — and
            // the launch-agent relaunch path (RecordingCoordinator) could then silently fail to
            // read the key before the session is unlocked.
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            // AfterFirstUnlock, not the (default) WhenUnlocked: a launch-agent relaunch after a
            // crash (RecordingCoordinator) can happen before the user unlocks the session, and a
            // summary run started from the CLI shouldn't fail to read its own key at that point.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        default:
            throw KeychainError.unexpectedStatus(existing)
        }
    }

    public func get(service: String, account: String) throws -> String? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Facade for the one secret this app currently stores in the Keychain: the summary provider's
/// API key (#48). `Config.summary` holds at most one active provider config at a time, so a
/// single fixed account is enough — there is no need to key by provider/endpoint/model. Every
/// call site that used to read/write `SummaryConfig.apiKey` goes through here instead.
public enum SummaryAPIKeyStore {
    public static let service = "eu.fmasi.parley.summary-api-key"
    public static let account = "default"

    /// Returns the stored key, or `""` if none is stored or the lookup fails. Callers already
    /// treat an empty string as "no key" throughout this codebase (see the summary providers'
    /// `Authorization` header logic), so this mirrors that instead of surfacing
    /// `Optional`/`throws` at every call site.
    public static func load(keychain: KeychainStoring = KeychainStore.shared) -> String {
        (try? keychain.get(service: service, account: account)) ?? ""
    }

    /// Stores `value`, or deletes the item when `value` is empty (the user cleared the field).
    /// Best-effort: a Keychain write failure here has no good recovery at a UI call site, so it's
    /// not thrown — but it is logged, same posture as `ConfigManager.save()`, so a rejected write
    /// (missing entitlement, locked, ACL) leaves a diagnostic trail instead of silently vanishing
    /// the key until the next summary run fails with an unexplained auth error.
    public static func save(_ value: String, keychain: KeychainStoring = KeychainStore.shared) {
        do {
            if value.isEmpty {
                try keychain.delete(service: service, account: account)
            } else {
                try keychain.set(value, service: service, account: account)
            }
        } catch {
            Logger.config.warning("Failed to save summary API key to Keychain: \(String(describing: error), privacy: .public)")
        }
    }
}
