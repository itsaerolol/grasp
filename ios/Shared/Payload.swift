import Foundation
import UniformTypeIdentifiers
import ImageIO

/// What the share sheet handed us, normalized into things LocalSend can carry.
enum OutgoingItem: Sendable {
    case file(url: URL, name: String, mime: String, size: Int64)
    case text(String)
}

enum PayloadBuilder {
    /// Copies every attachment into `workDir` (provider temp URLs die after the callback), applies the
    /// photo settings (JPG conversion, location, naming), packs folders (one .zip or their files), and
    /// turns URLs/plain text into `.text`.
    static func build(from providers: [NSItemProvider], workDir: URL,
                      settings: SendSettings = .defaults) async throws -> [OutgoingItem] {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var items: [OutgoingItem] = []
        for provider in providers {
            items += try await self.items(from: provider, workDir: workDir, settings: settings)
        }
        return items
    }

    private static func items(from p: NSItemProvider, workDir: URL, settings: SendSettings) async throws -> [OutgoingItem] {
        // Folders (Files app): one "<name>.zip", or every file inside.
        if p.hasItemConformingToTypeIdentifier(UTType.folder.identifier) {
            return try await packFolder(p, workDir: workDir, settings: settings).map(fileItem)
        }
        // Images first (Photos app). Prefer the original representation so we control conversion.
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await copyFile(p, type: .image, workDir: workDir)
            return [try processPhoto(url, settings: settings)]
        }
        // Files sometimes hands over nothing but a file URL (seen with an iCloud Drive folder). Send the item
        // it points at; the URL's own representation is just a plist of the path.
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), !hasFileContents(p),
           let url = try await loadObject(p, URL.self), url.isFileURL {
            return try itemsBehind(url, workDir: workDir, settings: settings)
        }
        // Web links -> text message (lands as a copyable popup on the PC).
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try await loadObject(p, URL.self) { return [.text(url.absoluteString)] }
        }
        // Files app / any file.
        if p.hasItemConformingToTypeIdentifier(UTType.data.identifier)
            && !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let url = try await copyFile(p, type: .data, workDir: workDir)
            return [fileItem(try zipCopiedDirectory(url, workDir: workDir))]
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try await loadObject(p, String.self) { return [.text(s)] }
        }
        // Anything else (the share rule admits every item): send whatever file it offers.
        if !p.registeredTypeIdentifiers.isEmpty {
            let url = try await copyFile(p, type: .item, workDir: workDir)
            return [fileItem(try zipCopiedDirectory(url, workDir: workDir))]
        }
        return []
    }

    /// True if the provider offers real file data, not only URL types (a file URL conforms to public.data).
    private static func hasFileContents(_ p: NSItemProvider) -> Bool {
        p.registeredTypeIdentifiers.contains { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .data) && !t.conforms(to: .url)
        }
    }

    /// The item behind a file URL: a folder is packed per the folder setting, a photo gets the photo settings,
    /// anything else is copied as is.
    static func itemsBehind(_ url: URL, workDir: URL, settings: SendSettings) throws -> [OutgoingItem] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return try pack(url, name: nil, workDir: workDir, mode: settings.folderMode).map(fileItem)
        }
        let copy = try copyOrZip(url, workDir: workDir)
        let isPhoto = UTType(filenameExtension: copy.pathExtension)?.conforms(to: .image) == true
        return [isPhoto ? try processPhoto(copy, settings: settings) : fileItem(copy)]
    }

    /// The item behind a file URL: a folder is zipped where it is, a file is copied into `workDir` under its
    /// own name. Coordinated reads, so an iCloud file that isn't downloaded yet is fetched first. The user's
    /// original is never moved or changed.
    static func copyOrZip(_ url: URL, workDir: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return try zipIfDirectory(url, workDir: workDir)
        }
        return try coordinatedCopy(url, workDir: workDir)
    }

    private static func coordinatedCopy(_ url: URL, workDir: URL) throws -> URL {
        let dest = uniqueURL(in: workDir, name: url.lastPathComponent)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { src in
            do { try FileManager.default.copyItem(at: src, to: dest) } catch { copyError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return dest
    }

    /// Reads the folder in place where the provider allows it, so it isn't copied before being packed.
    private static func packFolder(_ p: NSItemProvider, workDir: URL, settings: SendSettings) async throws -> [URL] {
        let identifier = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .folder) == true }
            ?? UTType.folder.identifier
        let suggestedName = p.suggestedName   // read here: the callback runs on another queue
        let mode = settings.folderMode
        return try await withCheckedThrowingContinuation { cont in
            _ = p.loadInPlaceFileRepresentation(forTypeIdentifier: identifier) { url, _, error in
                guard let url else { return cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                cont.resume(with: Result(catching: { try pack(url, name: suggestedName, workDir: workDir, mode: mode) }))
            }
        }
    }

    /// A folder as one "<name>.zip", or as copies of every file in it (see `flattenedCopies`).
    static func pack(_ dir: URL, name: String?, workDir: URL, mode: SendSettings.FolderMode) throws -> [URL] {
        switch mode {
        case .zip: return [try zipIfDirectory(dir, name: name, workDir: workDir)]
        case .files: return try flattenedCopies(of: dir, workDir: workDir)
        }
    }

    /// Every file under `dir`, copied into `workDir` one level deep in path order (hidden files skipped).
    /// Name clashes get a number ("notes 1.txt"). Packages such as .pages bundles are zipped so they stay
    /// whole. Each file is a coordinated read, so iCloud files that aren't downloaded are fetched first.
    static func flattenedCopies(of dir: URL, workDir: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey]
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw CocoaError(.fileReadUnknown) }
        var found: [URL] = []
        for case let url as URL in walker { found.append(url) }
        found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var copies: [URL] = []
        for url in found {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isPackage == true { copies.append(try zipIfDirectory(url, workDir: workDir)) }
            else if values.isRegularFile == true { copies.append(try coordinatedCopy(url, workDir: workDir)) }
        }
        return copies
    }

    /// For a directory we copied into `workDir` ourselves (e.g. a package such as a .pages bundle):
    /// zip it and delete the copy so the share doesn't hold the folder twice.
    private static func zipCopiedDirectory(_ url: URL, workDir: URL) throws -> URL {
        let zipped = try zipIfDirectory(url, workDir: workDir)
        if zipped != url { try? FileManager.default.removeItem(at: url) }
        return zipped
    }

    /// Zips a directory into `workDir/<name>.zip` through NSFileCoordinator's `.forUploading`, which writes
    /// the archive to disk itself, so the folder is never held in memory. Anything else is returned as is,
    /// and the directory itself is left alone (it may be the user's original, read in place).
    static func zipIfDirectory(_ url: URL, name: String? = nil, workDir: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return url }
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = trimmed.isEmpty ? url.lastPathComponent : trimmed
        let dest = uniqueURL(in: workDir, name: base + ".zip")
        var coordinatorError: NSError?
        var moveError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading, error: &coordinatorError) { zip in
            // The archive is deleted when this block returns: move it out, or copy if the move fails.
            do { try FileManager.default.moveItem(at: zip, to: dest) }
            catch {
                do { try FileManager.default.copyItem(at: zip, to: dest) } catch { moveError = error }
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let moveError { throw moveError }
        return dest
    }

    /// `loadObject(ofClass:)` has no async overload; bridge the completion handler.
    private static func loadObject<T>(_ p: NSItemProvider, _ type: T.Type) async throws -> T?
    where T: _ObjectiveCBridgeable, T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { cont in
            _ = p.loadObject(ofClass: type) { object, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: object) }
            }
        }
    }

    private static func copyFile(_ p: NSItemProvider, type: UTType, workDir: URL) async throws -> URL {
        // Never pick a URL type when real contents exist: public.file-url conforms to public.data, and its
        // representation is a plist of the path, not the file.
        let candidates = p.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: type) == true }
        let identifier = candidates.first { UTType($0)?.conforms(to: .url) == false } ?? candidates.first ?? type.identifier
        let suggestedName = p.suggestedName   // read here: the callback runs on another queue
        let isImage = type.conforms(to: .image)
        return try await withCheckedThrowingContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: identifier) { tmp, error in
                guard let tmp else { return cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                let name = fileName(suggested: suggestedName, tmp: tmp, isImage: isImage)
                let dest = uniqueURL(in: workDir, name: normalizedName(name))
                // Move, don't copy: the provider's temp file is ours until this handler returns, and a
                // multi-GB video shouldn't need twice its size in free space. Copy only if a move fails.
                do { try FileManager.default.moveItem(at: tmp, to: dest); cont.resume(returning: dest) }
                catch {
                    do { try FileManager.default.copyItem(at: tmp, to: dest); cont.resume(returning: dest) }
                    catch { cont.resume(throwing: error) }
                }
            }
        }
    }

    /// The sender's name if it has one. Otherwise (some Photos items) a readable one instead of the
    /// provider's temp name: "Photo 2026-10-14 01.30.12.webp".
    static func fileName(suggested: String?, tmp: URL, isImage: Bool, now: Date = Date()) -> String {
        let ext = tmp.pathExtension
        if let s = suggested?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            return (s as NSString).pathExtension.isEmpty && !ext.isEmpty ? s + "." + ext : s
        }
        let base = "\(isImage ? "Photo" : "File") \(stamp(now))"
        return ext.isEmpty ? base : base + "." + ext
    }

    /// "2026-10-14 01.30.12": sorts by time and has no characters Windows forbids in file names.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: date)
    }

    /// Photos hands over JPEG transcodes named ".jpeg"; everything else we produce says ".jpg".
    static func normalizedName(_ name: String) -> String {
        let ns = name as NSString
        return ns.pathExtension.lowercased() == "jpeg" ? ns.deletingPathExtension + ".jpg" : name
    }

    // MARK: - Photos

    /// Applies the photo settings in order: JPG conversion, location removal, date naming.
    static func processPhoto(_ url: URL, settings: SendSettings) throws -> OutgoingItem {
        var url = url
        var locationGone = false
        if settings.photoFormat == .jpg,
           let jpg = convertedToJPG(url, quality: settings.jpegQuality, stripLocation: settings.stripLocation) {
            url = jpg
            locationGone = settings.stripLocation
        }
        if settings.stripLocation, !locationGone {
            guard removeLocation(url) else { throw LSError.locationNotRemoved(url.lastPathComponent) }
        }
        if settings.namePhotosByDate { url = renamedByDate(url) }
        return fileItem(url)
    }

    /// HEIC/HEIF and still WebP -> JPEG via ImageIO, preserving orientation + EXIF. Animated WebP is left
    /// alone (a JPG would keep only the first frame). Kept for the default settings and the tests.
    static func convertToJPGIfNeeded(_ url: URL, quality: Double = SendSettings.defaults.jpegQuality,
                                     stripLocation: Bool = false) throws -> OutgoingItem {
        fileItem(convertedToJPG(url, quality: quality, stripLocation: stripLocation) ?? url)
    }

    /// The JPG written next to `url` (the original is deleted), or nil if `url` isn't a convertible photo.
    static func convertedToJPG(_ url: URL, quality: Double, stripLocation: Bool) -> URL? {
        let type = UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .heic) || type.conforms(to: .heif) || type.conforms(to: .webP)
        else { return nil }

        let out = url.deletingPathExtension().appendingPathExtension("jpg")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) == 1,
              let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        if stripLocation { props[kCGImagePropertyGPSDictionary] = kCFNull }   // kCFNull removes a property
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return out
    }

    /// Rewrites a photo in place without its GPS metadata, keeping its format. Lossless where ImageIO can copy
    /// the image data as is; otherwise re-encoded at full quality. False if the photo couldn't be rewritten.
    static func removeLocation(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src)
        else { return false }
        let count = CGImageSourceGetCount(src)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".nogps-" + url.lastPathComponent)
        var ok = false
        if let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, count, nil) {
            ok = CGImageDestinationCopyImageSource(dst, src, [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, nil)
        }
        if !ok, let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, count, nil) {
            for i in 0..<count {
                var props = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]) ?? [:]
                props[kCGImagePropertyGPSDictionary] = kCFNull
                props[kCGImageDestinationLossyCompressionQuality] = 1.0
                CGImageDestinationAddImageFromSource(dst, src, i, props as CFDictionary)
            }
            ok = CGImageDestinationFinalize(dst)
        }
        guard ok, (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }

    /// "Photo 2026-10-20 20.49.30.jpg" from the photo's EXIF date taken, or now if it has none.
    static func renamedByDate(_ url: URL) -> URL {
        let date = dateTaken(url) ?? Date()
        let ext = url.pathExtension
        let name = "Photo \(stamp(date))" + (ext.isEmpty ? "" : ".\(ext)")
        guard name != url.lastPathComponent else { return url }
        let dest = uniqueURL(in: url.deletingLastPathComponent(), name: name)
        return (try? FileManager.default.moveItem(at: url, to: dest)) != nil ? dest : url
    }

    static func dateTaken(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"   // EXIF, local time of the camera
        return f.date(from: raw)
    }

    static func fileItem(_ url: URL) -> OutgoingItem {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .file(url: url, name: url.lastPathComponent, mime: mime, size: size)
    }

    private static func uniqueURL(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        var n = 1
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        return candidate
    }
}
