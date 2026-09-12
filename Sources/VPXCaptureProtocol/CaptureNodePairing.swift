import CryptoKit
import Foundation

/// A QR-transferable, high-entropy credential created by the Mac Host. The
/// short verification code is only for human confirmation; it is not used as
/// cryptographic key material and must never be sent as a network password.
public struct CapturePairingCredential: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let secret: Data

    public init(sessionID: UUID = UUID(), secret: Data) throws {
        guard secret.count == 32 else { throw CapturePairingError.invalidCredential }
        self.sessionID = sessionID
        self.secret = secret
    }

    public static func create() throws -> CapturePairingCredential {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return try CapturePairingCredential(secret: secret)
    }

    /// Six digits shown on both devices to catch an accidental QR scan.
    public var verificationCode: String {
        let digest = SHA256.hash(data: secret + Data(sessionID.uuidString.utf8))
        let value = digest.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        } % 1_000_000
        return String(format: "%06u", value)
    }

    /// Compact QR/deep-link payload. The high-entropy credential remains the
    /// secret; the six-digit code is displayed separately for human checking.
    public var qrPayload: String {
        let encoded = (try? JSONEncoder().encode(self)) ?? Data()
        let base64 = encoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "vpxstudio://pair/" + base64
    }

    public init(qrPayload: String) throws {
        let prefix = "vpxstudio://pair/"
        guard qrPayload.hasPrefix(prefix) else { throw CapturePairingError.invalidCredential }
        var base64 = String(qrPayload.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let credential = try? JSONDecoder().decode(CapturePairingCredential.self, from: data) else {
            throw CapturePairingError.invalidCredential
        }
        try self.init(sessionID: credential.sessionID, secret: credential.secret)
    }
}

public struct CaptureEncryptedControlMessage: Codable, Sendable, Equatable {
    public let sessionID: UUID
    /// AES-GCM combined representation: nonce, ciphertext, and authentication tag.
    public let combinedSealedBox: Data

    public init(sessionID: UUID, combinedSealedBox: Data) {
        self.sessionID = sessionID
        self.combinedSealedBox = combinedSealedBox
    }
}

public enum CapturePairingError: LocalizedError, Equatable {
    case invalidCredential
    case sessionMismatch
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Capture pairing credentials must contain a 256-bit secret."
        case .sessionMismatch: "The encrypted control message belongs to a different pairing session."
        case .encryptionFailed: "Could not encrypt the Capture Node control message."
        case .decryptionFailed: "Could not authenticate or decrypt the Capture Node control message."
        }
    }
}

/// Encrypts the control plane with AES-GCM. The session ID is authenticated as
/// associated data, preventing a valid packet from being replayed into another
/// pairing session. Persist the credential in Keychain, never UserDefaults.
public struct CaptureControlMessageProtector: Sendable {
    private let credential: CapturePairingCredential
    private let key: SymmetricKey

    public init(credential: CapturePairingCredential) {
        self.credential = credential
        key = SymmetricKey(data: credential.secret)
    }

    public func seal(_ envelope: CaptureMessageEnvelope) throws -> CaptureEncryptedControlMessage {
        do {
            let cleartext = try JSONEncoder().encode(envelope)
            let combined = try sealPayload(cleartext)
            return CaptureEncryptedControlMessage(
                sessionID: credential.sessionID,
                combinedSealedBox: combined
            )
        } catch let error as CapturePairingError {
            throw error
        } catch {
            throw CapturePairingError.encryptionFailed
        }
    }

    public func open(_ encrypted: CaptureEncryptedControlMessage) throws -> CaptureMessageEnvelope {
        guard encrypted.sessionID == credential.sessionID else {
            throw CapturePairingError.sessionMismatch
        }
        do {
            let cleartext = try openPayload(encrypted.combinedSealedBox)
            return try JSONDecoder().decode(CaptureMessageEnvelope.self, from: cleartext)
        } catch {
            throw CapturePairingError.decryptionFailed
        }
    }

    /// Protects an arbitrary binary transport packet using this pairing session.
    public func sealPayload(_ cleartext: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.seal(
                cleartext,
                using: key,
                authenticating: associatedData
            )
            guard let combined = sealedBox.combined else {
                throw CapturePairingError.encryptionFailed
            }
            return combined
        } catch let error as CapturePairingError {
            throw error
        } catch {
            throw CapturePairingError.encryptionFailed
        }
    }

    /// Authenticates and opens an arbitrary binary transport packet.
    public func openPayload(_ encryptedPayload: Data) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encryptedPayload)
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: associatedData
            )
        } catch {
            throw CapturePairingError.decryptionFailed
        }
    }

    private var associatedData: Data {
        Data(credential.sessionID.uuidString.utf8)
    }
}
