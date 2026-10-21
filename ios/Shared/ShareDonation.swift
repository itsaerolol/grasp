import Foundation
import Intents
import UIKit

/// Puts the PC in the share sheet's TOP suggestion row (where AirDrop targets show), not just the app row.
/// Mechanism: donate an outgoing INSendMessageIntent whose conversation is the PC.
/// The extension declares IntentsSupported = [INSendMessageIntent] and reads `extensionContext.intent`.
enum ShareDonation {
    static func donate(_ peer: Peer) {
        let image = INImage(imageData: avatar().pngData() ?? Data())
        let person = INPerson(
            personHandle: INPersonHandle(value: peer.id, type: .unknown),
            nameComponents: nil, displayName: peer.alias, image: image,
            contactIdentifier: nil, customIdentifier: peer.id)
        let intent = INSendMessageIntent(
            recipients: [person], outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: peer.alias),
            conversationIdentifier: peer.id, serviceName: nil, sender: nil, attachments: nil)
        intent.setImage(image, forParameterNamed: \.speakableGroupName)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate { error in
            if let error { print("Grasp donation failed:", error) }
        }
    }

    /// The PC's picture in the suggestion row (iOS crops it to a circle and badges it with the app icon):
    /// the app icon's look, a near-black gradient, a white desktop, and its blue dot. Drawn at full size,
    /// because a symbol's default ~17pt image gets stretched and blurry there.
    static func avatar(size: CGFloat = 256) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(white: 0.20, alpha: 1).cgColor, UIColor(white: 0.04, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.40, weight: .medium)
            if let pc = UIImage(systemName: "desktopcomputer", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                pc.draw(at: CGPoint(x: (size - pc.size.width) / 2, y: (size - pc.size.height) / 2 + size * 0.03))
            }
            // The logo's blue dot, sitting above the screen's right corner.
            let d = size * 0.17
            UIColor(red: 0.04, green: 0.52, blue: 1, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: size * 0.64, y: size * 0.17, width: d, height: d))
        }
    }

    static func deleteAll() { INInteraction.deleteAll(completion: nil) }

    /// Which PC the user tapped in the suggestion row (nil = tapped the Grasp app icon).
    static func peerId(from intent: INIntent?) -> String? {
        (intent as? INSendMessageIntent)?.conversationIdentifier
    }
}
