import Foundation
import Intents
import UIKit

/// Puts the PC in the share sheet's TOP suggestion row (where AirDrop targets show), not just the app row.
/// Mechanism: donate an outgoing INSendMessageIntent whose conversation is the PC.
/// The extension declares IntentsSupported = [INSendMessageIntent] and reads `extensionContext.intent`.
enum ShareDonation {
    static func donate(_ peer: Peer) {
        let image = INImage(imageData: (UIImage(systemName: "desktopcomputer")?
            .withTintColor(.label, renderingMode: .alwaysOriginal).pngData()) ?? Data())
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

    static func deleteAll() { INInteraction.deleteAll(completion: nil) }

    /// Which PC the user tapped in the suggestion row (nil = tapped the Grasp app icon).
    static func peerId(from intent: INIntent?) -> String? {
        (intent as? INSendMessageIntent)?.conversationIdentifier
    }
}
