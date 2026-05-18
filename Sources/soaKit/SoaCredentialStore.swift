import Foundation
#if canImport(Security)
import Security
#endif

public struct SoaCredentialStore: Sendable {
    public static let defaultService = "dev.aiden.soaKit.credential"

    public let service: String
    public let account: String

    public init(service: String = defaultService, account: String = "default") {
        self.service = service
        self.account = account
    }

    public func save(_ credential: SoaCredential) throws {
        #if canImport(Security)
        let data = try JSONEncoder().encode(credential)
        var query = baseQuery
        query[kSecValueData as String] = data
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemDelete(baseQuery as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SoaError.keychainFailure("SecItemAdd failed with status \(status)")
        }
        #else
        throw SoaError.keychainUnavailable()
        #endif
    }

    public func load() throws -> SoaCredential? {
        #if canImport(Security)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SoaError.keychainFailure("SecItemCopyMatching returned a non-Data result")
            }
            do {
                return try JSONDecoder().decode(SoaCredential.self, from: data)
            } catch {
                throw SoaError.authMalformed("stored keychain credential is not decodable: \(error.localizedDescription)")
            }
        case errSecItemNotFound:
            return nil
        default:
            throw SoaError.keychainFailure("SecItemCopyMatching failed with status \(status)")
        }
        #else
        throw SoaError.keychainUnavailable()
        #endif
    }

    public func delete() throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SoaError.keychainFailure("SecItemDelete failed with status \(status)")
        }
        #else
        throw SoaError.keychainUnavailable()
        #endif
    }

    @discardableResult
    public func importAuthJSON(_ json: String) throws -> SoaCredential {
        guard let data = json.data(using: .utf8) else {
            throw SoaError.authMalformed("auth payload is not valid UTF-8")
        }
        let parsed = try parseAuthJSON(try JSONValue.decode(from: data))
        guard let credential = parsed.normalized.preferredCredential(for: nil) else {
            throw SoaError.credentialInsufficient()
        }
        try save(credential)
        return credential
    }

    private var baseQuery: [String: Any] {
        #if canImport(Security)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #else
        return [:]
        #endif
    }
}
