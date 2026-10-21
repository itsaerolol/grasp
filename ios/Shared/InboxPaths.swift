import Foundation
import UniformTypeIdentifiers

/// Windows -> iPhone: where things from the PC land. Everything goes in the app's Documents folder, which
/// Files shows as On My iPhone > Grasp (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
/// Same rules as ios/tools/lib.mjs `safeRelative` and the --fetch path in ls-send.mjs.
enum InboxPaths {
    static var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// The PC's name for the file, cleaned so it can never leave `root`: each path component has
    /// characters Files dislikes replaced, and ".", ".." and empty components are dropped. A folder's
    /// files keep their subfolders ("Trip/day 2/a.jpg").
    static func components(of fileName: String) -> [String] {
        let bad = CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters)
        let parts = fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { raw -> String in
            String(String.UnicodeScalarView(raw.unicodeScalars.map { bad.contains($0) ? "_" : $0 }))
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.isEmpty ? ["file"] : parts
    }

    /// A free path for `fileName` under `root`, creating its folders. Never overwrites: "photo 1.jpg".
    static func destination(for fileName: String, in root: URL = root) throws -> URL {
        let parts = components(of: fileName)
        var dir = root
        for folder in parts.dropLast() { dir.appendPathComponent(folder, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = parts.last!
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")); n += 1
        }
        return candidate
    }

    /// Deletes files from a cancelled pull, then any folders that are left empty, up to (not including) `root`.
    static func remove(_ files: [URL], below root: URL) {
        let fm = FileManager.default
        for file in files {
            try? fm.removeItem(at: file)
            var dir = file.deletingLastPathComponent().standardizedFileURL
            let top = root.standardizedFileURL.path
            while dir.path.hasPrefix(top + "/"), (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
                dir = dir.deletingLastPathComponent()
            }
        }
    }

    /// Photos and videos also go to the Photos library (if the setting is on).
    static func isPhotoOrVideo(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie)
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }
}
