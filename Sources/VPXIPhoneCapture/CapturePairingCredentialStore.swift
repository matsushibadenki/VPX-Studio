#if os(iOS)
import Foundation
import Security
import VPXCaptureProtocol

public enum CapturePairingCredentialStoreError: LocalizedError {
    case keychainFailure(OSStatus)
    case invalidStoredCredential

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status): "Keychain operation failed (" + String(status) + ")."
        case .invalidStoredCredential: "The saved Capture Node pairing credential is invalid."
        }
    }
}

/// Keychain-backed pairing credential persistence for the iPhone Capture Node.
/// Credentials are never stored in UserDefaults or inside a project document.
public enum CapturePairingCredentialStore {
    private static let service = "com.vpxstudio.capture-node.pairing"

    public static func save(_ credential: CapturePairingCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: credential.sessionID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData] = data
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CapturePairingCredentialStoreError.keychainFailure(status)
        }
    }

    public static func load(sessionID: UUID) throws -> CapturePairingCredential? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sessionID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CapturePairingCredentialStoreError.keychainFailure(status)
        }
        guard let credential = try? JSONDecoder().decode(CapturePairingCredential.self, from: data) else {
            throw CapturePairingCredentialStoreError.invalidStoredCredential
        }
        return credential
    }

    public static func remove(sessionID: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: sessionID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
