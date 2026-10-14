import UIKit
import SwiftUI

/// Principal class of the share extension. No compose sheet: tapping Grasp (or the PC in the
/// suggestion row) starts sending immediately; the sheet only shows status.
final class ShareViewController: UIViewController {
    private let engine = SendEngine()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareStatusView(
            engine: engine,
            onClose: { [weak self] in self?.finish(cancelled: false) },
            onCancel: { [weak self] in self?.engine.cancel(); self?.finish(cancelled: true) }
        ))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grasp-\(UUID().uuidString)", isDirectory: true)
        engine.start(providers: providers,
                     targetPeerId: ShareDonation.peerId(from: extensionContext?.intent),
                     workDir: workDir)
    }

    private func finish(cancelled: Bool) {
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(domain: "Grasp", code: NSUserCancelledError))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
