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
    /// converts HEIC/HEIF -> JPG, and turns URLs/plain text into `.text`.
    static func build(from providers: [NSItemProvider], workDir: URL) async throws -> [OutgoingItem] {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        var items: [OutgoingItem] = []
        for provider in providers {
            if let item = try await item(from: provider, workDir: workDir) { items.append(item) }
        }
        return items
    }

    private static func item(from p: NSItemProvider, workDir: URL) async throws -> OutgoingItem? {
        // Images first (Photos app). Prefer the original representation so we control conversion.
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let url = try await copyFile(p, type: .image, workDir: workDir)
            return try convertIfHEIC(url)
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
            return fileItem(url)
        }
        if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try await loadObject(p, String.self) { return .text(s) }
        }
        return nil
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
        let identifier = p.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true } ?? type.identifier
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

    /// HEIC/HEIF -> JPEG via ImageIO, preserving orientation + EXIF. Decision: always convert for Windows.
    static func convertIfHEIC(_ url: URL) throws -> OutgoingItem {
        let type = UTType(filenameExtension: url.pathExtension)
        guard let type, type.conforms(to: .heic) || type.conforms(to: .heif) else { return fileItem(url) }

        let out = url.deletingPathExtension().appendingPathExtension("jpg")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
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
