import SwiftUI

struct ShareStatusView: View {
    @ObservedObject var engine: SendEngine
    let onClose: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            VStack(spacing: 14) {
                icon.font(.system(size: 34, weight: .semibold)).frame(height: 40)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if case .sending(let p) = engine.phase {
                    ProgressView(value: p).progressViewStyle(.linear)
                }
                buttons
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .onChange(of: engine.phase) { _, phase in
            switch phase {
            case .done:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: onClose)
            case .failed:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            default: break
            }
        }
    }

    private var title: String {
        switch engine.phase {
        case .preparing: return "Preparing…"
        case .connecting(let pc): return "Connecting to \(pc)…"
        case .waitingForAccept(let pc): return "Accept on \(pc)"
        case .sending(let p): return "Sending \(Int(p * 100))%"
        case .done(let s): return s
        case .failed(let msg): return msg
        case .cancelling: return "Cancelling…"
        }
    }

    @ViewBuilder private var icon: some View {
        switch engine.phase {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .waitingForAccept: Image(systemName: "desktopcomputer").symbolEffect(.pulse)
        default: ProgressView().controlSize(.large)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch engine.phase {
        case .done, .cancelling: EmptyView()
        case .failed: Button("Close", action: onClose).buttonStyle(.borderedProminent)
        default: Button("Cancel", role: .cancel, action: onCancel)
        }
    }
}
