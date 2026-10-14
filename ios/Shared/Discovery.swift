import Foundation
import Darwin

/// Discovery without the multicast entitlement: LocalSend's "HTTP legacy" mode
/// (POST /register to every host on the /24). Needs only the Local Network permission.
enum Discovery {
    struct Found: Hashable, Sendable, Identifiable {
        var id: String { certFingerprint }
        let host: String
        let info: LSDeviceInfo
        let certFingerprint: String
        static func == (a: Found, b: Found) -> Bool { a.certFingerprint == b.certFingerprint }
        func hash(into h: inout Hasher) { h.combine(certFingerprint) }
    }

    /// Sweeps the phone's own /24, gently. Only ever started by a tap in the app: on managed (enterprise)
    /// Wi-Fi a wider or faster sweep gets the phone kicked off the network.
    static func scan(me: ClientIdentity.Material,
                     perHostTimeout: TimeInterval = 1.5,
                     concurrency: Int = 16) async -> [Found] {
        let hosts = scanTargets()
        guard !hosts.isEmpty else { return [] }
        let timeout = perHostTimeout, width = concurrency

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
                if let found = result { results.append(found) }
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

    /// Reach the pinned PC at its stored address (pinned GET /info). Never sweeps: a share must not be able
    /// to knock the phone off Wi-Fi. If the PC moved, the user re-adds it in the app.
    static func resolve(_ peer: Peer, me: ClientIdentity.Material) async -> Peer? {
        let direct = LSClient(host: peer.host, port: peer.port, expectedFingerprint: peer.certFingerprint,
                              me: me, connectTimeout: 3)
        guard (try? await direct.info()) != nil else { return nil }
        var p = peer; p.lastSeen = Date(); PeerStore.save(p); return p
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

    /// Hosts to probe: the phone's own /24, or its real subnet when that is smaller (a hotspot /28),
    /// minus itself and the network/broadcast addresses. Pure so it can be unit tested.
    static func scanTargets(ip: UInt32, mask: UInt32) -> [String] {
        let prefix = max(mask.nonzeroBitCount, 24)
        guard prefix <= 30 else { return [] }
        let m: UInt32 = ~UInt32(0) << UInt32(32 - prefix)
        let network = ip & m, broadcast = network | ~m
        // In a wider subnet the /24's .0 and .255 are ordinary hosts; only the real subnet's edges are excluded.
        let real: UInt32 = mask == 0 ? m : mask
        let realNet = ip & real, realBroadcast = realNet | ~real
        return (network...broadcast)
            .filter { $0 != ip && $0 != realNet && $0 != realBroadcast }
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
