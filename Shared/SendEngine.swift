import Foundation
import CryptoKit

/// One share = one LocalSend session. Drives state for the share extension UI.
@MainActor
final class SendEngine: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case connecting(String)          // alias
        case waitingForAccept(String)    // manual accept on PC (decision)
        case sending(Double)             // 0...1 overall
        case done(String)                // summary
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    private var activeClient: LSClient?
    private var activeSession: String?
    private var task: Task<Void, Never>?

    func start(providers: [NSItemProvider], targetPeerId: String?, workDir: URL) {
        #if DEBUG
        let probe = MemoryProbe.start(items: providers.count)
        task = Task {
            await run(providers: providers, targetPeerId: targetPeerId, workDir: workDir)
            probe.finish(phase: "\(phase)")
        }
        #else
        task = Task { await run(providers: providers, targetPeerId: targetPeerId, workDir: workDir) }
        #endif
    }

    func cancel() {
        task?.cancel()
        if let c = activeClient, let s = activeSession { Task { await c.cancel(sessionId: s) } }
    }

    private func run(providers: [NSItemProvider], targetPeerId: String?, workDir: URL) async {
        do {
            let me = try ClientIdentity.load()
            guard let stored = targetPeerId.flatMap(PeerStore.peer(id:)) ?? PeerStore.defaultPeer else {
                return phase = .failed("No PC paired. Open Grasp to pair your PC.")
            }
            let items = try await PayloadBuilder.build(from: providers, workDir: workDir)
            guard !items.isEmpty else { return phase = .failed("Nothing sendable in this share.") }

            phase = .connecting(stored.alias)
            guard let peer = await Discovery.resolve(stored, me: me) else {
                throw LSError.pcNotAnswering(alias: stored.alias, host: stored.host)
            }
            let client = LSClient(host: peer.host, port: peer.port, expectedFingerprint: peer.certFingerprint, me: me)
            activeClient = client

            let (dtos, files) = try describe(items)
            phase = .waitingForAccept(peer.alias)
            guard let session = try await client.prepareUpload(files: dtos, pin: peer.pin) else {
                ShareDonation.donate(peer)
                return phase = .done(summary(items))   // 204: text message shown on PC
            }
            activeSession = session.sessionId

            let accepted = files.filter { session.files[$0.id] != nil }
            let total = max(accepted.reduce(Int64(0)) { $0 + $1.size }, 1)
            var completed: Int64 = 0
            phase = .sending(0)
            for f in accepted {
                try Task.checkCancellation()
                let base = completed
                try await client.upload(sessionId: session.sessionId, fileId: f.id,
                                        token: session.files[f.id]!, fileURL: f.url) { frac in
                    let overall = Double(base) + frac * Double(f.size)
                    Task { @MainActor in self.phase = .sending(min(overall / Double(total), 1)) }
                }
                completed += f.size
            }
            ShareDonation.donate(peer)
            phase = .done(summary(items))
        } catch is CancellationError {
            phase = .failed("Cancelled")
        } catch {
            phase = .failed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: workDir)
    }

    struct FileRef { let id: String; let url: URL; let size: Int64 }

    /// A single text item becomes a LocalSend "message" (text/plain + preview, no upload).
    /// Text mixed with files is sent as a .txt file.
    func describe(_ items: [OutgoingItem]) throws -> ([LSFileDTO], [FileRef]) {
        if items.count == 1, case .text(let s) = items[0] {
            let data = Data(s.utf8)
            return ([LSFileDTO(id: UUID().uuidString, fileName: "\(UUID().uuidString).txt",
                               size: Int64(data.count), fileType: "text/plain", sha256: nil, preview: s)], [])
        }
        var dtos: [LSFileDTO] = [], refs: [FileRef] = []
        for item in items {
            let id = UUID().uuidString
            switch item {
            case .file(let url, let name, let mime, let size):
                dtos.append(LSFileDTO(id: id, fileName: name, size: size, fileType: mime,
                                      sha256: try sha256(url), preview: nil))
                refs.append(FileRef(id: id, url: url, size: size))
            case .text(let s):
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).txt")
                try Data(s.utf8).write(to: url)
                let size = Int64(s.utf8.count)
                dtos.append(LSFileDTO(id: id, fileName: "Note.txt", size: size, fileType: "text/plain",
                                      sha256: try sha256(url), preview: nil))
                refs.append(FileRef(id: id, url: url, size: size))
            }
        }
        return (dtos, refs)
    }

    /// Streaming hash (1MB chunks) so large files don't blow the extension memory cap.
    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func summary(_ items: [OutgoingItem]) -> String {
        if items.count == 1, case .text = items[0] { return "Sent text" }
        return items.count == 1 ? "Sent 1 item" : "Sent \(items.count) items"
    }
}

#if DEBUG
/// Debug-only: samples the extension's footprint during a share and stores the peak in the App Group
/// defaults (key "debug.lastShare"), so it can be read off a device over USB. Not in Release builds.
final class MemoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let items: Int
    private let began = Date()

    private init(items: Int) { self.items = items }

    static func start(items: Int) -> MemoryProbe {
        let p = MemoryProbe(items: items)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak p] in p?.sample() }
        p.timer = t
        t.resume()
        return p
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return }
        lock.withLock { peak = max(peak, info.phys_footprint) }
    }

    func finish(phase: String) {
        sample()
        timer?.cancel()
        let mb = lock.withLock { Double(peak) / 1_048_576 }
        AppConfig.defaults.set([
            "peakMB": (mb * 10).rounded() / 10, "items": items, "phase": phase,
            "seconds": Date().timeIntervalSince(began).rounded(), "at": Date().description,
        ], forKey: "debug.lastShare")
    }
}
#endif
