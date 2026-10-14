import Foundation

enum AppConfig {
    /// App Group shared by the app and the share extension.
    /// Also used as the keychain access group (iOS accepts app groups there), so no Team ID prefix plumbing.
    static let appGroup = "group.com.itsaerolol.grasp"

    static let alias = "Grasp iPhone"
    static let deviceModel = "iPhone"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup)! }

    /// JPEG quality for HEIC conversion.
    static let jpegQuality: CGFloat = 0.9
}
