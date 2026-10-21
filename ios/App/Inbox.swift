import Photos
import SwiftUI
import UIKit

/// Windows -> iPhone. Grasp for Windows can't reach the phone, so it queues things and this pulls them over
/// the paired PC's pinned mTLS connection whenever the app is open (PairingView polls every few seconds).
/// Files land in Files > On My iPhone > Grasp; photos and videos also go to the Photos library if the setting
/// is on; text goes on the clipboard. Each item is marked done on the PC only after it's saved, so an
/// interrupted pull simply resumes next time.
@MainActor
final class Inbox: ObservableObject {
    struct Received: Identifiable, Equatable {
        enum Kind: Equatable { case file(URL, photos: Bool), text(String) }
        let id = UUID()
        let name: String
        let kind: Kind
    }

    enum Availability: Equatable {
        case unknown
        case ready
        /// The PC answers but this phone isn't paired by code (paired before code pairing, or unpaired on the PC).
        case needsCodePairing
        /// Stock LocalSend: no outbox.
        case notSupported
    }

    @Published private(set) var receiving: (name: String, index: Int, count: Int, progress: Double)?
    @Published private(set) var recent: [Received] = []
    @Published private(set) var availability: Availability = .unknown
    private var pulling = false

    /// Unpaired: what came from that PC no longer belongs on screen.
    func reset() {
        recent = []
        availability = .unknown
    }

    /// Pulls everything the PC has queued. Silent when there's nothing or the PC is off.
    func pull(peer: Peer, me: ClientIdentity.Material, report: (PairingModel.Toast.Kind, String) -> Void) async {
        guard !pulling else { return }
        pulling = true
        defer { pulling = false; receiving = nil }

        let client = LSClient(host: peer.host, port: peer.port, expectedFingerprint: peer.certFingerprint,
                              me: me, connectTimeout: 4)
        let items: [LSOutboxItem]
        do {
            items = try await client.outbox()
            availability = .ready
        } catch LSError.notPairedByCode {
            return availability = .needsCodePairing
        } catch LSError.badStatus(404, _) {
            return availability = .notSupported
        } catch {
            return   // PC off or out of reach: try again next round
        }
        guard !items.isEmpty else { return }

        let settings = SendSettings.load()
        var got: [Received] = []
        var saved: [URL] = []          // files written in this pull, deleted again if the PC cancels it
        var forPhotos: [URL] = []      // added to Photos only once the pull ends, so a cancel leaves no copy there
        var failure: String?
        for (i, item) in items.enumerated() {
            do {
                switch item.kind {
                case "text":
                    guard let text = item.text else { continue }
                    UIPasteboard.general.string = text
                    got.append(Received(name: text, kind: .text(text)))
                case "file":
                    guard let name = item.fileName else { continue }
                    let shown = InboxPaths.components(of: name).last ?? name
                    receiving = (shown, i + 1, items.count, 0)
                    let dest = try InboxPaths.destination(for: name)
                    do {
                        try await client.downloadOutboxFile(id: item.id, to: dest) { [weak self] p in
                            Task { @MainActor in
                                if let r = self?.receiving, r.index == i + 1 { self?.receiving = (r.name, r.index, r.count, p) }
                            }
                        }
                    } catch {
                        // The PC's X clears its queue and cuts the stream. If the item is gone from the queue,
                        // the whole send was cancelled there: keep nothing from this pull.
                        if let left = try? await client.outbox(), !left.contains(where: { $0.id == item.id }) {
                            InboxPaths.remove(saved + [dest], below: InboxPaths.root)
                            report(.error, LSError.cancelledOnPC.localizedDescription)
                            return
                        }
                        throw error
                    }
                    saved.append(dest)
                    let toPhotos = settings.saveMediaToPhotos && InboxPaths.isPhotoOrVideo(dest)
                    if toPhotos { forPhotos.append(dest) }
                    got.append(Received(name: shown, kind: .file(dest, photos: toPhotos)))
                default:
                    continue   // something a newer PC sends that this version doesn't know: leave it queued
                }
                try await client.outboxDone(id: item.id)
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        for url in forPhotos { _ = await Self.saveToPhotos(url) }
        recent = Array((got.reversed() + recent).prefix(20))
        if !got.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            report(.success, Self.summary(got, from: peer.alias))
        }
        if let failure { report(.error, failure) }
    }

    private static func summary(_ got: [Received], from pc: String) -> String {
        if got.count == 1, case .text = got[0].kind { return "Copied text from \(pc)" }
        return got.count == 1 ? "Received \(got[0].name)" : "Received \(got.count) items from \(pc)"
    }

    /// Adds a copy to the library; the file stays in Files either way. False if access was refused or Photos
    /// doesn't take the format.
    private static func saveToPhotos(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset()
                    .addResource(with: InboxPaths.isVideo(url) ? .video : .photo, fileURL: url, options: options)
            }
            return true
        } catch {
            return false
        }
    }
}

/// The "From PC" part of the main screen: what's arriving, what arrived, and how to send.
struct InboxSection: View {
    @ObservedObject var inbox: Inbox
    let pcName: String
    let copied: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            if let r = inbox.receiving {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Receiving \(r.name)").lineLimit(1)
                        Spacer()
                        if r.count > 1 { Text("\(r.index) of \(r.count)").foregroundStyle(.secondary).monospacedDigit() }
                    }
                    ProgressView(value: r.progress)
                }
                .padding(.vertical, 4)
            }
            ForEach(inbox.recent) { item in
                Button { open(item) } label: { row(item) }
                    .tint(.primary)
            }
            if inbox.receiving == nil && inbox.recent.isEmpty {
                Text("Nothing yet").foregroundStyle(.secondary)
            }
        } header: {
            Text("From \(pcName)")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        switch inbox.availability {
        case .needsCodePairing:
            return "To receive from the PC, unpair here and pair again with the code from Grasp's tray menu."
        case .notSupported:
            return "This PC runs LocalSend, which can't send to Grasp. Grasp for Windows can."
        case .unknown, .ready:
            return "On the PC, drag files onto Grasp's corner card, right-click › Send to › iPhone (Grasp), or use the tray menu. They arrive while Grasp is open, in Files › On My iPhone › Grasp."
        }
    }

    @ViewBuilder private func row(_ item: Inbox.Received) -> some View {
        switch item.kind {
        case .file(_, let photos):
            Label {
                VStack(alignment: .leading) {
                    Text(item.name).lineLimit(1)
                    Text(photos ? "In Files and Photos" : "In Files").font(.footnote).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: photos ? "photo" : "doc") }
        case .text(let text):
            Label {
                VStack(alignment: .leading) {
                    Text(text).lineLimit(2)
                    Text("Copied · tap to copy again").font(.footnote).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "doc.on.clipboard") }
        }
    }

    private func open(_ item: Inbox.Received) {
        switch item.kind {
        case .file(let url, _):
            // Opens the Files app on the folder holding the file.
            if let files = URL(string: "shareddocuments://" + url.deletingLastPathComponent().path) { openURL(files) }
        case .text(let text):
            UIPasteboard.general.string = text
            copied(text)
        }
    }
}
