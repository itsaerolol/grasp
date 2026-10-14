import Foundation
import Darwin

/// Discovery without the multicast entitlement: LocalSend's "HTTP legacy" mode
/// (POST /register to every host on the /24). Needs only the Local Network permission.
enum Discovery {
    struct Found: Hashable, Sendable {
        let host: String
        let info: LSDeviceInfo
        let certFingerprint: String
        static func == (a: Found, b: Found) -> Bool { a.certFingerprint == b.certFingerprint }
        func hash(into h: inout Hasher) { h.combine(certFingerprint) }
    }

    /// Scans the local /24. `stopWhen` lets the extension bail out as soon as it finds its pinned PC.
    static func scan(me: ClientIdentity.Material,
                     perHostTimeout: TimeInterval = 1.5,
                     concurrency: Int = 48,
                     stopWhen: (@Sendable (Found) -> Bool)? = nil) async -> [Found] {
        guard let base = localSubnetBase() else { return [] }
        let myIP = localIPv4()
        // Annotated: comparing against the optional `myIP` otherwise infers [String?].
        let hosts: [String] = (1...254).map { "\(base).\($0)" }.filter { $0 != myIP }

        return await withTaskGroup(of: Found?.self) { group in
            var results: [Found] = []
            var iterator = hosts.makeIterator()
            func addNext() -> Bool {
                guard let host = iterator.next() else { return false }
                group.addTask { await probe(host: host, me: me, timeout: perHostTimeout) }
                return true
            }
            for _ in 0..<concurrency { if !addNext() { break } }
            while let result = await group.next() {
                if let found = result {
                    results.append(found)
                    if stopWhen?(found) == true { group.cancelAll(); break }
                }
                _ = addNext()
            }
            return Array(Set(results))
        }
    }

    static func probe(host: String, me: ClientIdentity.Material, timeout: TimeInterval) async -> Found? {
        let client = LSClient(host: host, expectedFingerprint: nil, me: me, connectTimeout: timeout)
        guard let info = try? await client.register(), let fp = client.serverFingerprint,
              fp != me.fingerprint else { return nil }
        return Found(host: host, info: info, certFingerprint: fp)
    }

    /// Resolve the pinned PC: try its last IP, else rescan and match by fingerprint (DHCP moved it).
    static func resolve(_ peer: Peer, me: ClientIdentity.Material) async -> Peer? {
        let direct = LSClient(host: peer.host, port: peer.port, expectedFingerprint: peer.certFingerprint,
                              me: me, connectTimeout: 2)
        if (try? await direct.info()) != nil {
            var p = peer; p.lastSeen = Date(); PeerStore.save(p); return p
        }
        let hits = await scan(me: me, stopWhen: { $0.certFingerprint == peer.certFingerprint })
        guard let hit = hits.first(where: { $0.certFingerprint == peer.certFingerprint }) else { return nil }
        var p = peer; p.host = hit.host; p.lastSeen = Date(); PeerStore.save(p); return p
    }

    // MARK: Interfaces

    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &buf, socklen_t(buf.count),
                        nil, 0, NI_NUMERICHOST)
            return String(cString: buf)
        }
        return nil
    }

    /// "192.168.1" for 192.168.1.42. v1 assumes a /24 (home routers). Larger subnets: v2.
    static func localSubnetBase() -> String? {
        guard let ip = localIPv4() else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }
}
