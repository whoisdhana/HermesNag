import Foundation
import Security

/// Reads the bearer token from the login Keychain.
///
/// The token is created by the server's install.sh and stored with:
///   security add-generic-password -a hermesnag -s hermesnag-token -w '<token>'
/// It never lives in the repo or in UserDefaults (spec Rule 7).

public enum Keychain {
    public static let account = "hermesnag"
    public static let service = "hermesnag-token"

    public enum KeychainError: Error, LocalizedError, Equatable {
        case notFound
        case unexpectedData
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "No token in Keychain. Run: security add-generic-password "
                     + "-a hermesnag -s hermesnag-token -w '<token>'"
            case .unexpectedData:
                return "Keychain item is not valid UTF-8 text"
            case .status(let s):
                return "Keychain error \(s)"
            }
        }
    }

    public static func readToken(account: String = account,
                                 service: String = service) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            throw KeychainError.notFound
        default:
            throw KeychainError.status(status)
        }
    }

    public static var hasToken: Bool {
        (try? readToken()) != nil
    }
}
