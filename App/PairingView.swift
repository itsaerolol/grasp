import SwiftUI

/// The containing app exists to: create the mTLS identity, pair one PC, and test.
/// Everything day-to-day happens in the share extension.
@MainActor
final class PairingModel: ObservableObject {
    @Published var me: ClientIdentity.Material?
    @Published var paired: Peer? = PeerStore.defaultPeer
    @Published var found: [Discovery.Found] = []
    @Published var scanning = false
    @Published var status: String?
    @Published var manualHost = ""

    func boot() {
        do { me = try ClientIdentity.loadOrCreate() }
        catch { status = "Identity setup failed: \(error.localizedDescription)" }
    }

    /// First scan also triggers the iOS Local Network permission prompt.
    func scan() async {
        guard let me else { return }
        scanning = true; status = nil
        found = await Discovery.scan(me: me).sorted { $0.info.alias < $1.info.alias }
        scanning = false
        if found.isEmpty { status = "No PCs found. Open LocalSend on the PC, same Wi-Fi, and allow Local Network access." }
    }

    func addManual() async {
        guard let me, !manualHost.isEmpty else { return }
        if let hit = await Discovery.probe(host: manualHost, me: me, timeout: 3) { pair(hit) }
        else { status = "Nothing answering LocalSend at \(manualHost):\(LS.port)." }
    }

    func pair(_ f: Discovery.Found) {
        let peer = Peer(alias: f.info.alias, host: f.host, port: LS.port, certFingerprint: f.certFingerprint,
                        deviceModel: f.info.deviceModel, pin: nil, lastSeen: Date())
        PeerStore.save(peer, makeDefault: true)
        ShareDonation.donate(peer)
        paired = peer
        status = "Paired. Check that LocalSend on the PC shows fingerprint ending \(f.certFingerprint.suffix(8))."
    }

    func unpair() {
        if let p = paired { PeerStore.remove(p) }
        ShareDonation.deleteAll()
        paired = nil
    }

    func sendTest() async {
        guard let me, let peer = paired else { return }
        status = "Waiting for you to accept on the PC..."
        do {
            guard let p = await Discovery.resolve(peer, me: me) else { throw LSError.unreachable(peer.alias) }
            let client = LSClient(host: p.host, port: p.port, expectedFingerprint: p.certFingerprint, me: me)
            let text = "Grasp test from iPhone"
            _ = try await client.prepareUpload(files: [
                LSFileDTO(id: UUID().uuidString, fileName: "\(UUID().uuidString).txt",
                          size: Int64(text.utf8.count), fileType: "text/plain", sha256: nil, preview: text)
            ], pin: p.pin)
            status = "Test delivered."
            ShareDonation.donate(p)
        } catch { status = error.localizedDescription }
    }
}

struct PairingView: View {
    @StateObject private var model = PairingModel()

    var body: some View {
        NavigationStack {
            List {
                if let peer = model.paired {
                    Section("Paired PC") {
                        LabeledContent(peer.alias, value: peer.host)
                        Text("Cert \(peer.certFingerprint.prefix(8))…\(peer.certFingerprint.suffix(8))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Send test message") { Task { await model.sendTest() } }
                        Button("Unpair", role: .destructive) { model.unpair() }
                    }
                }
                Section {
                    Button(model.scanning ? "Scanning…" : "Scan network") { Task { await model.scan() } }
                        .disabled(model.scanning || model.me == nil)
                    ForEach(model.found, id: \.certFingerprint) { f in
                        Button { model.pair(f) } label: {
                            LabeledContent(f.info.alias, value: f.host)
                        }
                    }
                } header: { Text("Find PC") } footer: {
                    Text("PC needs LocalSend open with encryption on. Grasp sends from the share sheet.")
                }
                Section("Manual IP") {
                    HStack {
                        TextField("192.168.1.20", text: $model.manualHost)
                            .keyboardType(.decimalPad).textInputAutocapitalization(.never)
                        Button("Add") { Task { await model.addManual() } }
                    }
                }
                if let status = model.status { Section { Text(status).font(.callout) } }
                if let me = model.me {
                    Section("This iPhone") {
                        Text(me.fingerprint).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Grasp")
        }
        .task { model.boot() }
    }
}
