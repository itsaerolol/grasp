import Foundation

/// A paired PC. Identity = server TLS cert fingerprint; host is just the last known address.
struct Peer: Codable, Identifiable, Hashable, Sendable {
    var id: String { certFingerprint }
    var alias: String
    var host: String
    var port: Int
    var certFingerprint: String
    var deviceModel: String?
    var pin: String?
    var lastSeen: Date
}

/// v1 stores exactly one default PC (decision: single target, zero-tap send).
/// Kept as an array internally so multi-PC is a UI change, not a migration.
enum PeerStore {
    private static let key = "peers.v1"
    private static let defaultKey = "peers.default"

    static var all: [Peer] {
        guard let data = AppConfig.defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Peer].self, from: data)) ?? []
    }

    static var defaultPeer: Peer? {
        let id = AppConfig.defaults.string(forKey: defaultKey)
        return all.first { $0.id == id } ?? all.first
    }

    static func peer(id: String) -> Peer? { all.first { $0.id == id } }

    static func save(_ peer: Peer, makeDefault: Bool = false) {
        var list = all.filter { $0.id != peer.id }
        list.append(peer)
        AppConfig.defaults.set(try? JSONEncoder().encode(list), forKey: key)
        if makeDefault { AppConfig.defaults.set(peer.id, forKey: defaultKey) }
    }

    static func remove(_ peer: Peer) {
        AppConfig.defaults.set(try? JSONEncoder().encode(all.filter { $0.id != peer.id }), forKey: key)
    }
}
