import Foundation
import Security
import CryptoKit
import X509
import SwiftASN1
import _CryptoExtras

/// mTLS client identity.
///
/// LocalSend's server (packages/core/src/http/server/mod.rs) sets
/// `mandatory_client_auth = web.share == Disabled`, i.e. a client certificate is REQUIRED
/// in normal operation. It accepts any self-signed cert whose signature verifies
/// (client_cert_verifier.rs -> verify_cert_from_der(cert, None)). LocalSend itself uses RSA-2048,
/// so we match that to stay inside what its x509 verifier is known to accept.
///
/// Created once by the main app; the share extension only loads it (shared via the App Group keychain group).
enum ClientIdentity {
    static let keyTag = Data("com.itsaerolol.grasp.client-key".utf8)
    static let certLabel = "Grasp Client Certificate"

    struct Material: @unchecked Sendable {
        let identity: SecIdentity
        /// Uppercase hex SHA-256 of our cert DER. Sent as `info.fingerprint`
        /// (server checks it equals the presented cert on /register).
        let fingerprint: String
    }

    static func loadOrCreate() throws -> Material {
        if let m = try? load() { return m }
        try create()
        return try load()
    }

    static func load() throws -> Material {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessGroup as String: AppConfig.appGroup,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let ref = item else { throw LSError.noClientIdentity }
        let identity = ref as! SecIdentity

        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity, &cert)
        guard let cert else { throw LSError.noClientIdentity }
        let der = SecCertificateCopyData(cert) as Data
        return Material(identity: identity, fingerprint: Fingerprint.of(der: der))
    }

    static func create() throws {
        try? delete()

        // 1. RSA-2048 key, permanent, shared with the extension.
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessGroup as String: AppConfig.appGroup,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as [String: Any],
        ]
        var err: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &err) else {
            throw err!.takeRetainedValue() as Error
        }
        guard let pkcs1 = SecKeyCopyExternalRepresentation(secKey, &err) as Data? else {
            throw err!.takeRetainedValue() as Error
        }

        // 2. Self-signed X.509 cert signed by that key (swift-certificates).
        let rsaKey = try _RSA.Signing.PrivateKey(derRepresentation: pkcs1)
        let name = try DistinguishedName { CommonName("Grasp") }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(rsaKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(86_400 * 365 * 10),
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: Certificate.PrivateKey(rsaKey)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        let der = Data(serializer.serializedBytes)

        // 3. Store the cert; keychain pairs it with the key into a SecIdentity.
        guard let secCert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw LSError.noClientIdentity
        }
        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCert,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessGroup as String: AppConfig.appGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addCert as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() throws {
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
            kSecAttrAccessGroup as String: AppConfig.appGroup,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrAccessGroup as String: AppConfig.appGroup,
        ] as CFDictionary)
    }
}

enum Fingerprint {
    /// LocalSend format: uppercase hex SHA-256 of cert DER (packages/core/src/crypto/cert.rs fingerprint_from_cert_der).
    static func of(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}
