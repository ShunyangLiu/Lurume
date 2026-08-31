import Foundation
import Security

protocol TranslationAPIKeyStoring: Sendable {
    func read() async throws -> String?
    func save(_ apiKey: String) async throws
    func delete() async throws
}

struct KeychainTranslationAPIKeyStore: TranslationAPIKeyStoring, Sendable {
    static let service = "app.lurume.Lurume.translation-api"
    static let account = "openai-compatible"

    func read() async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            var query = Self.baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess,
                  let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                throw TranslationAPIKeyStoreError(status: status)
            }
            return value
        }.value
    }

    func save(_ apiKey: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let data = apiKey.data(using: .utf8) else {
                throw TranslationAPIKeyStoreError.invalidValue
            }
            let updateStatus = SecItemUpdate(
                Self.baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else {
                throw TranslationAPIKeyStoreError(status: updateStatus)
            }

            var attributes = Self.baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TranslationAPIKeyStoreError(status: addStatus)
            }
        }.value
    }

    func delete() async throws {
        try await Task.detached(priority: .userInitiated) {
            let status = SecItemDelete(Self.baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TranslationAPIKeyStoreError(status: status)
            }
        }.value
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum TranslationAPIKeyStoreError: LocalizedError, Equatable {
    case invalidValue
    case keychain(OSStatus)

    init(status: OSStatus) {
        self = .keychain(status)
    }

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "API Key 无法编码。"
        case .keychain:
            "无法访问 macOS 钥匙串。上一份成功配置保持不变。"
        }
    }
}
