import SwiftUI
import UIKit

/// The containing app exists to: create the mTLS identity, pair one PC, and test.
/// Everything day-to-day happens in the share extension.
@MainActor
final class PairingModel: ObservableObject {
    struct Toast: Equatable { enum Kind { case success, error }; let kind: Kind; let text: String }

    @Published var me: ClientIdentity.Material?
    @Published var paired: Peer? = PeerStore.defaultPeer
    @Published var found: [Discovery.Found] = []
    @Published var scanning = false
    @Published var scanned = false
    /// nil = checking.
    @Published var reachable: Bool?
    @Published var sending = false
    @Published var adding = false
    @Published var manualError: String?
    @Published var toast: Toast?
    private var toastTask: Task<Void, Never>?

    func boot() async {
        do { me = try ClientIdentity.loadOrCreate() }
        catch { show(.error, "Identity setup failed: \(error.localizedDescription)"); return }
        if paired == nil { await scan() } else { await refreshStatus() }
    }

    /// Direct check first; if the PC moved (DHCP), `resolve` rescans and updates the stored address.
    func refreshStatus() async {
        guard let me, let peer = paired else { return }
        reachable = nil
        let direct = LSClient(host: peer.host, port: peer.port, expectedFingerprint: peer.certFingerprint,
                              me: me, connectTimeout: 2)
        if (try? await direct.info()) != nil { reachable = true; return }
        if let moved = await Discovery.resolve(peer, me: me) { paired = moved; reachable = true }
        else { reachable = false }
    }

    /// First scan also triggers the iOS Local Network permission prompt.
    func scan() async {
        guard let me, !scanning else { return }
        scanning = true
        found = await Discovery.scan(me: me).sorted { $0.info.alias < $1.info.alias }
        scanning = false; scanned = true
    }

    /// Returns true when paired, so the caller can dismiss its sheet.
    func addManual(_ raw: String) async -> Bool {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let me, !host.isEmpty else { return false }
        adding = true; manualError = nil
        defer { adding = false }
        if let hit = await Discovery.probe(host: host, me: me, timeout: 3) { pair(hit); return true }
        manualError = "Nothing answering at \(host). Is Grasp running on the PC?"
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        return false
    }

    func pair(_ f: Discovery.Found) {
        let peer = Peer(alias: f.info.alias, host: f.host, port: LS.port, certFingerprint: f.certFingerprint,
                        deviceModel: f.info.deviceModel, pin: nil, lastSeen: Date())
        // One default PC (locked decision): pairing a different PC replaces the old one.
        if let old = paired, old.id != peer.id { PeerStore.remove(old); ShareDonation.deleteAll() }
        PeerStore.save(peer, makeDefault: true)
        ShareDonation.donate(peer)
        paired = peer; reachable = true
        found.removeAll { $0.certFingerprint == f.certFingerprint }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        show(.success, "Paired with \(peer.alias)")
    }

    func unpair() {
        if let p = paired { PeerStore.remove(p) }
        ShareDonation.deleteAll()
        paired = nil; reachable = nil; found = []; scanned = false
        Task { await scan() }
    }

    func sendTest() async {
        guard let me, let peer = paired, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            guard let p = await Discovery.resolve(peer, me: me) else { throw LSError.unreachable(peer.alias) }
            paired = p; reachable = true
            let client = LSClient(host: p.host, port: p.port, expectedFingerprint: p.certFingerprint, me: me)
            let text = "Grasp test from iPhone"
            _ = try await client.prepareUpload(files: [
                LSFileDTO(id: UUID().uuidString, fileName: "\(UUID().uuidString).txt",
                          size: Int64(text.utf8.count), fileType: "text/plain", sha256: nil, preview: text)
            ], pin: p.pin)
            ShareDonation.donate(p)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show(.success, "Delivered to \(p.alias)")
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if case LSError.unreachable = error { reachable = false }
            show(.error, error.localizedDescription)
        }
    }

    func copyIdentity() {
        guard let me else { return }
        UIPasteboard.general.string = me.fingerprint
        show(.success, "Copied this iPhone's ID")
    }

    func copyPCFingerprint() {
        guard let p = paired else { return }
        UIPasteboard.general.string = p.certFingerprint
        show(.success, "Copied \(p.alias)'s ID")
    }

    func show(_ kind: Toast.Kind, _ text: String) {
        toast = Toast(kind: kind, text: text)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 3))
            if !Task.isCancelled { toast = nil }
        }
    }
}

// MARK: - Screen

struct PairingView: View {
    @StateObject private var model = PairingModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFinder = false
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            List {
                if let peer = model.paired {
                    pairedSection(peer)
                } else {
                    FindPCSection(model: model, showManual: $showManual)
                }
            }
            .navigationTitle("Grasp")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
            .overlay(alignment: .bottom) { ToastView(toast: model.toast).padding(.bottom, 12) }
            .animation(.snappy, value: model.toast)
            .animation(.snappy, value: model.paired)
        }
        .sheet(isPresented: $showFinder) { FinderSheet(model: model, showManual: $showManual) }
        .sheet(isPresented: $showManual) { ManualIPSheet(model: model) }
        .task { await model.boot() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.paired != nil, !model.sending { Task { await model.refreshStatus() } }
        }
        .onChange(of: model.paired) { _, new in if new != nil { showFinder = false; showManual = false } }
    }

    @ViewBuilder private func pairedSection(_ peer: Peer) -> some View {
        Section {
            PairedPCRow(peer: peer, reachable: model.reachable)
                .swipeActions(edge: .trailing) {
                    Button("Unpair", role: .destructive) { model.unpair() }
                }
                .contextMenu {
                    Button("Copy ID", systemImage: "doc.on.doc") { model.copyPCFingerprint() }
                    Button("Unpair", systemImage: "xmark.circle", role: .destructive) { model.unpair() }
                }
        }
        Section {
            Button {
                Task { await model.sendTest() }
            } label: {
                HStack(spacing: 8) {
                    if model.sending { ProgressView().tint(.white) }
                    Text(model.sending ? "Accept on \(peer.alias)" : "Send test message")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.sending || model.me == nil)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var menu: some View {
        Menu {
            if model.paired != nil {
                Button("Pair a different PC", systemImage: "plus") { showFinder = true }
            }
            Button("Enter IP address", systemImage: "network") { showManual = true }
            Button("Copy this iPhone's ID", systemImage: "iphone") { model.copyIdentity() }
                .disabled(model.me == nil)
            if model.paired != nil {
                Divider()
                Button("Unpair", systemImage: "xmark.circle", role: .destructive) { model.unpair() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}

// MARK: - Components

private struct PairedPCRow: View {
    let peer: Peer
    let reachable: Bool?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.alias).font(.headline).lineLimit(1)
                Text(peer.host).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusChip(reachable: reachable)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Colour encodes the value: green = answered just now, orange = didn't, grey = still checking.
private struct StatusChip: View {
    let reachable: Bool?

    var body: some View {
        HStack(spacing: 5) {
            if reachable == nil { ProgressView().controlSize(.mini) }
            else { Circle().fill(reachable == true ? Color.green : Color.orange).frame(width: 7, height: 7) }
            Text(reachable == nil ? "Checking" : reachable == true ? "Online" : "Offline")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

/// Found PCs, with scanning / empty states. Used inline when unpaired and in the "Pair a different PC" sheet.
private struct FindPCSection: View {
    @ObservedObject var model: PairingModel
    @Binding var showManual: Bool
    var excludePaired = false

    private var rows: [Discovery.Found] {
        excludePaired ? model.found.filter { $0.certFingerprint != model.paired?.certFingerprint } : model.found
    }

    var body: some View {
        Section {
            if model.scanning && rows.isEmpty {
                ForEach(0..<2, id: \.self) { _ in
                    FoundRow(alias: "Scanning PC", host: "000.000.0.000").redacted(reason: .placeholder)
                }
            }
            ForEach(rows, id: \.certFingerprint) { f in
                Button { model.pair(f) } label: { FoundRow(alias: f.info.alias, host: f.host, chevron: true) }
                    .buttonStyle(.plain)
            }
            if !model.scanning && rows.isEmpty && model.scanned {
                ContentUnavailableView {
                    Label("No PCs found", systemImage: "desktopcomputer")
                } actions: {
                    Button("Scan again") { Task { await model.scan() } }
                    Button("Enter IP address") { showManual = true }
                }
                .listRowBackground(Color.clear)
            }
        } header: {
            HStack {
                Text("Nearby PCs")
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                else {
                    Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Scan again")
                        .disabled(model.me == nil)
                }
            }
        }
        if !rows.isEmpty || model.scanning {
            Section {
                Button { showManual = true } label: { Label("Enter IP address", systemImage: "network") }
            }
        }
    }
}

private struct FoundRow: View {
    let alias: String
    let host: String
    var chevron = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer").font(.title3).frame(width: 40, height: 40)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(alias).font(.body.weight(.medium))
                Text(host).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct FinderSheet: View {
    @ObservedObject var model: PairingModel
    @Binding var showManual: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { FindPCSection(model: model, showManual: $showManual, excludePaired: true) }
                .navigationTitle("Pair a different PC")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { if !model.scanned { await model.scan() } }
        .presentationDetents([.medium, .large])
    }
}

/// Own small step (like Roku / Hue "connect manually"), so the numpad never lingers on the main screen.
private struct ManualIPSheet: View {
    @ObservedObject var model: PairingModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @FocusState private var focused: Bool

    private var canAdd: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && !model.adding }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("172.20.10.228", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .onChange(of: host) { _, _ in model.manualError = nil }
                } header: { Text("IP address") } footer: {
                    if let error = model.manualError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.footnote)
                    }
                }
            }
            .navigationTitle("Add PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.adding { ProgressView() } else { Button("Add", action: add).disabled(!canAdd) }
                }
            }
        }
        .presentationDetents([.height(260)])
        .onAppear { focused = true; model.manualError = nil }
    }

    private func add() {
        guard canAdd else { return }
        focused = false
        Task {
            if await model.addManual(host) { dismiss() } else { focused = true }
        }
    }
}

private struct ToastView: View {
    let toast: PairingModel.Toast?

    var body: some View {
        if let toast {
            HStack(spacing: 10) {
                Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(toast.kind == .success ? Color.green : Color.orange)
                Text(toast.text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
