import Foundation
import Security

/// Supabase credentials for reading the analytics tables.
///
/// `serviceKey` is the **service_role** key: it bypasses RLS and can read and
/// write every table in the project. That is why it lives in the Keychain and
/// never in a plist, a defaults key, or a file on disk.
struct ObservorCredentials: Codable, Sendable, Equatable {
    var supabaseURL: String
    var serviceKey: String

    var isComplete: Bool {
        !supabaseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !serviceKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Normalised base URL with any trailing slash removed, so path joining is
    /// predictable regardless of how it was typed in Settings.
    var baseURL: URL? {
        var trimmed = supabaseURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed)
    }
}

enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String?
            return message ?? "Keychain error \(status)."
        }
    }
}

/// Keychain-backed storage for the Supabase credentials.
///
/// Adapted from `ios-ggyst/KeychainTokenStore.swift` — same read/update/insert
/// shape, different service identifier and payload.
struct KeychainSecretStore {
    private let service = "com.Ingram.observor.secrets"
    private let account = "supabase-credentials"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    nonisolated init() {}

    func load() throws -> ObservorCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }

        return try decoder.decode(ObservorCredentials.self, from: data)
    }

    func save(_ credentials: ObservorCredentials) throws {
        let data = try encoder.encode(credentials)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // This Mac only, and only once unlocked: the key is not worth
            // syncing to iCloud Keychain or exposing pre-login.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query.merge(attributes) { _, newValue in newValue }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
