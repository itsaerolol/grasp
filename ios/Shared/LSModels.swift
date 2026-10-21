import Foundation

/// LocalSend protocol v2.2. Spec: github.com/localsend/protocol (README.md).
/// Server behavior verified against localsend/localsend packages/core (Oct 2026).
enum LS {
    static let port = 53317
    static let version = "2.2"
    static let api = "/api/localsend/v2"
    /// Grasp for Windows extension, advertised as `grasp: N` in /info and /register. 1: code pairing.
    /// 2: also the outbox (Windows -> iPhone: this app pulls what the PC queued).
    static let graspApi = "/api/grasp/v1"
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
    /// Set by Grasp for Windows: it pairs by a 3-digit code shown on the PC.
    var grasp: Int?

    var supportsCodePairing: Bool { (grasp ?? 0) >= 1 }
    var supportsOutbox: Bool { (grasp ?? 0) >= 2 }
}

/// Windows -> iPhone: one thing Grasp for Windows queued for this phone (GET /api/grasp/v1/outbox).
/// Same shape as windows/core/src/outbox.rs `OutItem::wire` and the mock.
struct LSOutboxItem: Codable, Identifiable, Equatable, Sendable {
    var kind: String          // "file" | "text"
    var id: String
    /// A folder's files keep their path under the folder's name, with "/" ("Trip/day 2/a.jpg").
    var fileName: String?
    var size: Int64?
    var fileType: String?
    var text: String?
}

struct LSOutboxList: Codable, Sendable {
    var items: [LSOutboxItem]
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
    /// The paired PC didn't answer at its stored address (Grasp doesn't sweep the network on its own).
    case pcNotAnswering(alias: String, host: String)
    case fingerprintMismatch(expected: String, got: String)
    case pinRequired
    case rejected
    case busy
    case tooManyRequests
    case checksumMismatch
    case badStatus(Int, String)
    case noClientIdentity
    case pairingNotOpen
    case wrongCode(attemptsLeft: Int?)
    case pairingLocked
    /// "Remove location" is on but a photo couldn't be rewritten without it; never send it with GPS.
    case locationNotRemoved(String)
    /// The PC's outbox only serves a phone paired by code (403).
    case notPairedByCode

    var errorDescription: String? {
        switch self {
        case .pcNotAnswering(let alias, let host):
            return "Can't reach \(alias) at \(host). Is Grasp running on it? If its IP changed, re-add it in Grasp."
        case .unreachable(let host): return "Can't reach \(host). Is Grasp running on the PC, on the same Wi-Fi?"
        case .fingerprintMismatch: return "PC identity changed. Re-pair in the Grasp app."
        case .pinRequired: return "PC requires a PIN. Turn off PIN in LocalSend or set it in Grasp."
        case .rejected: return "Declined on the PC, or nobody tapped Accept in 30 seconds. Try again."
        case .busy: return "PC is busy with another transfer."
        case .tooManyRequests: return "PC is rate limiting. Try again in a moment."
        case .checksumMismatch: return "File got corrupted in transit. Try again."
        case .badStatus(let code, let body): return "PC returned \(code). \(body)"
        case .noClientIdentity: return "Open the Grasp app once to set up this phone."
        case .pairingNotOpen: return "Choose Pair iPhone in Grasp's menu on the PC, then enter its code."
        case .wrongCode(let left):
            return left.map { "Wrong code. \($0) \($0 == 1 ? "try" : "tries") left." } ?? "Wrong code."
        case .pairingLocked: return "Too many wrong codes. Choose Pair iPhone on the PC again."
        case .notPairedByCode:
            return "To receive from the PC, pair again with the code shown in Grasp's tray menu."
        case .locationNotRemoved(let name):
            return "Couldn't remove the location from \(name). Turn off Remove location in Grasp's settings to send it."
        }
    }

    /// Status mapping for POST /api/grasp/v1/pair (same codes as windows/core and the mock).
    static func fromPairing(status: Int, body: Data) -> LSError {
        switch status {
        case 401:
            let left = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["attemptsLeft"] as? Int
            return .wrongCode(attemptsLeft: left)
        case 409: return .pairingNotOpen
        case 429: return .pairingLocked
        default: return .badStatus(status, String(data: body, encoding: .utf8) ?? "")
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
