import Foundation

/// What the share extension does to items automatically. Edited on the app's Settings screen, stored in the
/// App Group defaults, and read by the extension at the start of every share.
struct SendSettings: Equatable, Sendable {
    enum PhotoFormat: String, CaseIterable, Sendable {
        case jpg        // HEIC/HEIF and still WebP become JPG (the default)
        case original   // photos are sent in whatever format they're in
    }
    enum FolderMode: String, CaseIterable, Sendable {
        case zip        // one "<name>.zip" (the default)
        case files      // every file inside, flattened into one level
    }

    var photoFormat: PhotoFormat = .jpg
    /// JPG quality for converted photos, 0.5...1.
    var jpegQuality: Double = 0.9
    /// Remove GPS location from photos before sending. Videos are not changed.
    var stripLocation = false
    /// Name photos "Photo <date taken>" instead of their own name (e.g. IMG_1234).
    var namePhotosByDate = false
    /// A single link or text goes over as a LocalSend message (pops up on the PC and lands on its clipboard).
    /// Off: it's sent as Note.txt.
    var textAsMessage = true
    var folderMode: FolderMode = .zip
    /// Windows -> iPhone: photos and videos from the PC also go to the Photos library (everything always
    /// lands in Files > On My iPhone > Grasp).
    var saveMediaToPhotos = true

    static let defaults = SendSettings()
    static let jpegQualityRange: ClosedRange<Double> = 0.5...1

    private enum Key {
        static let photoFormat = "settings.photoFormat", jpegQuality = "settings.jpegQuality"
        static let stripLocation = "settings.stripLocation", namePhotosByDate = "settings.namePhotosByDate"
        static let textAsMessage = "settings.textAsMessage", folderMode = "settings.folderMode"
        static let saveMediaToPhotos = "settings.saveMediaToPhotos"
    }

    static func load(from d: UserDefaults = AppConfig.defaults) -> SendSettings {
        var s = SendSettings()
        if let v = d.string(forKey: Key.photoFormat).flatMap(PhotoFormat.init) { s.photoFormat = v }
        if d.object(forKey: Key.jpegQuality) != nil {
            s.jpegQuality = min(max(d.double(forKey: Key.jpegQuality), jpegQualityRange.lowerBound), jpegQualityRange.upperBound)
        }
        if d.object(forKey: Key.stripLocation) != nil { s.stripLocation = d.bool(forKey: Key.stripLocation) }
        if d.object(forKey: Key.namePhotosByDate) != nil { s.namePhotosByDate = d.bool(forKey: Key.namePhotosByDate) }
        if d.object(forKey: Key.textAsMessage) != nil { s.textAsMessage = d.bool(forKey: Key.textAsMessage) }
        if let v = d.string(forKey: Key.folderMode).flatMap(FolderMode.init) { s.folderMode = v }
        if d.object(forKey: Key.saveMediaToPhotos) != nil { s.saveMediaToPhotos = d.bool(forKey: Key.saveMediaToPhotos) }
        return s
    }

    func save(to d: UserDefaults = AppConfig.defaults) {
        d.set(photoFormat.rawValue, forKey: Key.photoFormat)
        d.set(jpegQuality, forKey: Key.jpegQuality)
        d.set(stripLocation, forKey: Key.stripLocation)
        d.set(namePhotosByDate, forKey: Key.namePhotosByDate)
        d.set(textAsMessage, forKey: Key.textAsMessage)
        d.set(folderMode.rawValue, forKey: Key.folderMode)
        d.set(saveMediaToPhotos, forKey: Key.saveMediaToPhotos)
    }
}
