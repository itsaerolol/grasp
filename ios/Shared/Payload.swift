import Foundation
import UniformTypeIdentifiers
import ImageIO

/// What the share sheet handed us, normalized into things LocalSend can carry.
enum OutgoingItem: Sendable {
    case file(url: URL, name: String, mime: String, size: Int64)
    case text(String)
}

enum PayloadBuilder {
    /// Copies every attachment into `workDir` (provider temp URLs die after the callback),
    /// converts HEIC/HEIF -> JPG, zips folders, and turns URLs/plain text into `.text`.
    static func build(from providers: [NSItemProvider], workDir: URL) async throws -> [OutgoingItem] {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var items: [OutgoingItem] = []
        for provider in providers {
            if let item = try await item(from: provider, workDir: workDir) { items.append(item) }
        }
        return items
    }

    private static func item(from p: NSItemProvider, workDir: URL) async throws -> OutgoingItem? {
        // Folders (Files app) become one "<name>.zip".
        if p.hasItemConformingToTypeIdentifier(UTType.folder.identifier) {
            return fileItem(try await zipFolder(p, workDir: workDir))
        }
        // Images first (Photos app). Prefer the original representation so we control conversion.
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await copyFile(p, type: .image, workDir: workDir)
            return try convertToJPGIfNeeded(url)
        }
        // Files sometimes hands over nothing but a file URL (seen with an iCloud Drive folder). Send the item
        // it points at, zipped if it's a folder; the URL's own representation is just a plist of the path.
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), !hasFileContents(p),
           let url = try await loadObject(p, URL.self), url.isFileURL {
            return fileItem(try copyOrZip(url, workDir: workDir))
        }
        // Web links -> text message (lands as a copyable popup on the PC).
        if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = try await loadObject(p, URL.self) { return .text(url.absoluteString) }
        }
        // Files app / any file.
        if p.hasItemConformingToTypeIdentifier(UTType.data.identifier)
            && !p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let url = try await copyFile(p, type: .data, workDir: workDir)
            return fileItem(try zipCopiedDirectory(url, workDir: workDir))
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try await loadObject(p, String.self) { return .text(s) }
        }
        // Anything else (the share rule admits every item): send whatever file it offers.
        if !p.registeredTypeIdentifiers.isEmpty {
            let url = try await copyFile(p, type: .item, workDir: workDir)
            return fileItem(try zipCopiedDirectory(url, workDir: workDir))
        }
        return nil
    }

    /// True if the provider offers real file data, not only URL types (a file URL conforms to public.data).
    private static func hasFileContents(_ p: NSItemProvider) -> Bool {
        p.registeredTypeIdentifiers.contains { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .data) && !t.conforms(to: .url)
        }
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

    /// Reads the folder in place where the provider allows it, so it isn't copied before being zipped.
    private static func zipFolder(_ p: NSItemProvider, workDir: URL) async throws -> URL {
        let identifier = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .folder) == true }
            ?? UTType.folder.identifier
        let suggestedName = p.suggestedName   // read here: the callback runs on another queue
        return try await withCheckedThrowingContinuation { cont in
            _ = p.loadInPlaceFileRepresentation(forTypeIdentifier: identifier) { url, _, error in
                guard let url else { return cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                cont.resume(with: Result(catching: { try zipIfDirectory(url, name: suggestedName, workDir: workDir) }))
            }
        }
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(isImage ? "Photo" : "File") \(f.string(from: now))"
        return ext.isEmpty ? base : base + "." + ext
    }

    /// Photos hands over JPEG transcodes named ".jpeg"; everything else we produce says ".jpg".
    static func normalizedName(_ name: String) -> String {
        let ns = name as NSString
        return ns.pathExtension.lowercased() == "jpeg" ? ns.deletingPathExtension + ".jpg" : name
    }

    /// HEIC/HEIF and still WebP -> JPEG via ImageIO, preserving orientation + EXIF. Decision: photos always
    /// arrive on Windows as JPG. Animated WebP is left alone (a JPG would keep only the first frame).
    static func convertToJPGIfNeeded(_ url: URL) throws -> OutgoingItem {
        let type = UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .heic) || type.conforms(to: .heif) || type.conforms(to: .webP)
        else { return fileItem(url) }

        let out = url.deletingPathExtension().appendingPathExtension("jpg")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) == 1,
              let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return fileItem(url) }
        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = AppConfig.jpegQuality
        CGImageDestinationAddImageFromSource(dst, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return fileItem(url) }
        try? FileManager.default.removeItem(at: url)
        return fileItem(out)
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
