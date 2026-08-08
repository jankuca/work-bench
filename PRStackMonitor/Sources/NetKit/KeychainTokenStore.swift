#if canImport(Security)
import Foundation
import Security

/// A credential in the login keychain, one generic-password item per service.
///
/// This is the only file in the package that is not portable, which is why it is fenced
/// rather than split into its own module: `canImport(Security)` is false on Linux, so CI
/// compiles everything around it and skips this.
///
/// It lives in `NetKit` rather than in either service kit because both integrations store
/// a credential the same way, and the item's `account` is the only thing that differs.
///
/// Why the app has to be signed with a *stable* identity (IMPLEMENTATION_PLAN §0): the
/// item's ACL records the designated requirement of the process that created it. An
/// ad-hoc signature changes on every rebuild, so every rebuild looks like a different
/// program and macOS re-prompts. The self-signed `PRStackMonitor Local` certificate keeps
/// that requirement constant.
public struct KeychainTokenStore: TokenProvider {
    /// Matches the app's bundle identifier so the items are attributable in Keychain Access.
    public static let defaultService = "com.jankuca.PRStackMonitor"

    /// One item per integration, so revoking Linear cannot disturb GitHub.
    ///
    /// The type itself lives outside this file's `canImport(Security)` fence
    /// (``KeychainAccount``) so that ``CredentialChain`` — which is portable — can name an
    /// account on a platform that has no Keychain to read it from.
    public typealias Account = KeychainAccount

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        case malformedData

        public var description: String {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            case .malformedData:
                return "the stored credential is not valid UTF-8"
            }
        }
    }

    public let service: String
    public let account: Account

    public init(service: String = KeychainTokenStore.defaultService, account: Account = .github) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
    }

    public func token() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let raw = String(data: data, encoding: .utf8) else {
                throw Failure.malformedData
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An item holding an empty string is indistinguishable, to every caller, from
            // no item at all — so report it the same way and let the connect prompt appear.
            guard !trimmed.isEmpty else { throw MissingCredential(service: account.rawValue) }
            return trimmed
        case errSecItemNotFound:
            throw MissingCredential(service: account.rawValue)
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    /// Writes the token, replacing whatever was there.
    public func save(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { throw Failure.malformedData }

        // Update first, add second. Deleting and re-adding would also work, but it drops
        // the item's ACL along with it, which is what makes macOS re-prompt for access —
        // the exact thing the stable signing identity exists to avoid.
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw Failure.unexpectedStatus(updateStatus)
        }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
    }

    /// Removes the item. Deleting something that is not there is a success, not an error —
    /// "disconnect" is idempotent.
    public func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }

    public var hasToken: Bool {
        (try? token()) != nil
    }
}
#endif
