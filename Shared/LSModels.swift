import Foundation

/// LocalSend protocol v2.2. Spec: github.com/localsend/protocol (README.md).
/// Server behavior verified against localsend/localsend packages/core (Oct 2026).
enum LS {
    static let port = 53317
    static let version = "2.2"
    static let api = "/api/localsend/v2"
}

/// Used for /register request+response, /info response, and prepare-upload `info`.
/// In HTTPS mode the meaningful identity of a peer is the SHA-256 of its TLS cert (DER, uppercase hex),
/// NOT the `fingerprint` body field the server returns (that is an internal token).
struct LSDeviceInfo: Codable, Equatable, Sendable {
    var alias: String
    var version: String
    var deviceModel: String?
    var deviceType: String?
    var fingerprint: String?
    var port: Int?
    var `protocol`: String?
    var download: Bool?
}

struct LSFileDTO: Codable, Sendable {
    var id: String
    var fileName: String
    var size: Int64
    /// MIME type, e.g. "image/jpeg", "text/plain".
    var fileType: String
    var sha256: String?
    /// For a text message: the text itself (single file, text/plain). Receiver shows a popup, no upload.
    var preview: String?
}

struct LSPrepareUploadRequest: Codable, Sendable {
    var info: LSDeviceInfo
    var files: [String: LSFileDTO]
}

struct LSPrepareUploadResponse: Codable, Sendable {
    var sessionId: String
    /// fileId -> token
    var files: [String: String]
}

enum LSError: LocalizedError {
    case unreachable(String)
    case fingerprintMismatch(expected: String, got: String)
    case pinRequired
    case rejected
    case busy
    case tooManyRequests
    case checksumMismatch
    case badStatus(Int, String)
    case noClientIdentity

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): return "Can't reach PC at \(host). Is LocalSend open and on the same Wi-Fi?"
        case .fingerprintMismatch: return "PC identity changed. Re-pair in the Grasp app."
        case .pinRequired: return "PC requires a PIN. Turn off PIN in LocalSend or set it in Grasp."
        case .rejected: return "Declined on the PC."
        case .busy: return "PC is busy with another transfer."
        case .tooManyRequests: return "PC is rate limiting. Try again in a moment."
        case .checksumMismatch: return "File got corrupted in transit. Try again."
        case .badStatus(let code, let body): return "PC returned \(code). \(body)"
        case .noClientIdentity: return "Open the Grasp app once to set up this phone."
        }
    }

    static func from(status: Int, body: String) -> LSError {
        switch status {
        case 401: return .pinRequired
        case 403: return .rejected
        case 409: return .busy
        case 422: return .checksumMismatch
        case 429: return .tooManyRequests
        default: return .badStatus(status, body)
        }
    }
}
