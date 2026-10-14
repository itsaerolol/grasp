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

    /// Scans the phone's subnet (its real netmask, capped at a /20), own /24 first so the common case is fast.
    /// `stopWhen` lets the extension bail out as soon as it finds its pinned PC.
    static func scan(me: ClientIdentity.Material,
                     perHostTimeout: TimeInterval? = nil,
                     concurrency: Int? = nil,
                     stopWhen: (@Sendable (Found) -> Bool)? = nil) async -> [Found] {
        let hosts = scanTargets()
        guard !hosts.isEmpty else { return [] }
        let wide = hosts.count > 254
        let timeout = perHostTimeout ?? (wide ? 1.0 : 1.5)
        let width = concurrency ?? (wide ? 128 : 48)

        return await withTaskGroup(of: Found?.self) { group in
            var results: [Found] = []
            var iterator = hosts.makeIterator()
            func addNext() -> Bool {
                guard let host = iterator.next() else { return false }
                group.addTask { await probe(host: host, me: me, timeout: timeout) }
                return true
            }
            for _ in 0..<width { if !addNext() { break } }
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

    /// IPv4 address and netmask of en0, as host-order integers.
    static func localInterface() -> (ip: UInt32, mask: UInt32)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET), String(cString: ifa.ifa_name) == "en0" else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // BSD trims trailing zero bytes from netmask sockaddrs: only the first sa_len bytes are valid.
            let valid = Int(mask.pointee.sa_len)
            let raw = UnsafeRawPointer(mask)
            var m: UInt32 = 0
            for i in 0..<4 { m = m << 8 | (4 + i < valid ? UInt32(raw.load(fromByteOffset: 4 + i, as: UInt8.self)) : 0) }
            return (ip, m)
        }
        return nil
    }

    static func dotted(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }

    /// Hosts to probe: everything in the phone's subnet except itself, the network and broadcast addresses.
    /// Subnets wider than a /20 are clamped to the /20 around the phone; /31 and /32 have nothing to scan.
    /// Pure so it can be unit tested.
    static func scanTargets(ip: UInt32, mask: UInt32) -> [String] {
        let prefix = max(mask.nonzeroBitCount, 20)
        guard prefix <= 30 else { return [] }
        let m: UInt32 = ~UInt32(0) << UInt32(32 - prefix)
        let network = ip & m, broadcast = network | ~m
        let ownBlock = ip & 0xFFFF_FF00
        let inOwn = (max(network, ownBlock)...min(broadcast, ownBlock | 0xFF))
        let rest = (network...broadcast).filter { $0 & 0xFFFF_FF00 != ownBlock }
        return (Array(inOwn) + rest)
            .filter { $0 != ip && $0 != network && $0 != broadcast }
            .map(dotted)
    }

    static func scanTargets() -> [String] {
        guard let i = localInterface() else { return [] }
        return scanTargets(ip: i.ip, mask: i.mask)
    }
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
}
