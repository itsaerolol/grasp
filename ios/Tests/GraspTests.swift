import XCTest
import CryptoKit
import UniformTypeIdentifiers
import ImageIO

/// Shared/ is compiled straight into this bundle (same as the app and the extension), so no @testable import.
final class FingerprintTests: XCTestCase {
    func testKnownVector() {
        // SHA-256("abc"), uppercase hex, as LocalSend's fingerprint_from_cert_der formats it.
        XCTAssertEqual(Fingerprint.of(der: Data("abc".utf8)),
                       "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
    }

    func testShapeIs64UppercaseHexChars() {
        let fp = Fingerprint.of(der: Data([0, 1, 2, 3, 250, 251]))
        XCTAssertEqual(fp.count, 64)
        XCTAssertEqual(fp, fp.uppercased())
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit })
    }
}

final class ConvertIfHEICTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func fixture(as name: String) throws -> URL {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "heic"))
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    func testHEICBecomesJPGAndOriginalIsRemoved() throws {
        let heic = try fixture(as: "IMG_0001.HEIC")
        guard case .file(let url, let name, let mime, let size) = try PayloadBuilder.convertToJPGIfNeeded(heic) else {
            return XCTFail("expected a file item")
        }
        XCTAssertEqual(name, "IMG_0001.jpg")
        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertGreaterThan(size, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path))
        // Real JPEG: SOI marker, and ImageIO reads it back as JPEG.
        let head = try Data(contentsOf: url).prefix(2)
        XCTAssertEqual(Array(head), [0xFF, 0xD8])
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier)
    }

    func testLowercaseHEICExtensionAlsoConverts() throws {
        let heic = try fixture(as: "photo.heic")
        guard case .file(_, let name, _, _) = try PayloadBuilder.convertToJPGIfNeeded(heic) else { return XCTFail() }
        XCTAssertEqual(name, "photo.jpg")
    }

    func testNonHEICPassesThroughUntouched() throws {
        let pdf = dir.appendingPathComponent("Report.pdf")
        try Data("%PDF-1.1".utf8).write(to: pdf)
        guard case .file(let url, let name, let mime, let size) = try PayloadBuilder.convertToJPGIfNeeded(pdf) else { return XCTFail() }
        XCTAssertEqual(url, pdf)
        XCTAssertEqual(name, "Report.pdf")
        XCTAssertEqual(mime, "application/pdf")
        XCTAssertEqual(size, 8)
    }

    private func fixture(_ resource: String, _ ext: String, as name: String) throws -> URL {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: resource, withExtension: ext))
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    func testStillWebPBecomesJPG() throws {
        let webp = try fixture("sample", "webp", as: "Photo 2026-10-14 01.30.12.webp")
        guard case .file(let url, let name, let mime, _) = try PayloadBuilder.convertToJPGIfNeeded(webp) else { return XCTFail() }
        XCTAssertEqual(name, "Photo 2026-10-14 01.30.12.jpg")
        XCTAssertEqual(mime, "image/jpeg")
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(2)), [0xFF, 0xD8])
        XCTAssertFalse(FileManager.default.fileExists(atPath: webp.path))
    }

    func testAnimatedWebPIsLeftAlone() throws {
        let webp = try fixture("animated", "webp", as: "sticker.webp")
        guard case .file(let url, let name, _, _) = try PayloadBuilder.convertToJPGIfNeeded(webp) else { return XCTFail() }
        XCTAssertEqual(name, "sticker.webp", "a JPG would keep only the first frame")
        XCTAssertEqual(url, webp)
    }

    func testJpegExtensionIsNormalizedToJpg() {
        XCTAssertEqual(PayloadBuilder.normalizedName("IMG_0001.jpeg"), "IMG_0001.jpg")
        XCTAssertEqual(PayloadBuilder.normalizedName("IMG_0001.JPEG"), "IMG_0001.jpg")
        XCTAssertEqual(PayloadBuilder.normalizedName("a.b.jpeg"), "a.b.jpg")
        XCTAssertEqual(PayloadBuilder.normalizedName("shot.png"), "shot.png")
        XCTAssertEqual(PayloadBuilder.normalizedName("jpeg"), "jpeg")
    }
}

@MainActor
final class DescribeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ bytes: String) throws -> OutgoingItem {
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return PayloadBuilder.fileItem(url)
    }

    func testSingleTextIsAMessage() throws {
        let (dtos, refs) = try SendEngine().describe([.text("https://example.com/")])
        XCTAssertEqual(dtos.count, 1)
        XCTAssertTrue(refs.isEmpty, "a message uploads nothing")
        let d = dtos[0]
        XCTAssertEqual(d.fileType, "text/plain")
        XCTAssertEqual(d.preview, "https://example.com/")
        XCTAssertEqual(d.size, Int64("https://example.com/".utf8.count))
        XCTAssertTrue(d.fileName.hasSuffix(".txt"))
        XCTAssertNil(d.sha256)
    }

    func testTextSizeIsUTF8Bytes() throws {
        let (dtos, _) = try SendEngine().describe([.text("héllo ✓")])
        XCTAssertEqual(dtos[0].size, Int64("héllo ✓".utf8.count))
    }

    func testTextPlusFileSendsNoteTxtNotAMessage() throws {
        let items: [OutgoingItem] = [.text("remember this"), try file("a.pdf", "pdf-bytes")]
        let (dtos, refs) = try SendEngine().describe(items)
        XCTAssertEqual(dtos.count, 2)
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(dtos.allSatisfy { $0.preview == nil }, "only a lone text item is a message")
        let note = try XCTUnwrap(dtos.first { $0.fileName == "Note.txt" })
        XCTAssertEqual(note.fileType, "text/plain")
        XCTAssertEqual(note.size, Int64("remember this".utf8.count))
        XCTAssertNotNil(note.sha256)
    }

    func testFilesGetStreamedSHA256() throws {
        let (dtos, refs) = try SendEngine().describe([try file("a.txt", "abc"), try file("b.txt", "")])
        XCTAssertEqual(dtos.count, 2)
        XCTAssertEqual(refs.count, 2)
        let a = try XCTUnwrap(dtos.first { $0.fileName == "a.txt" })
        // SHA-256("abc"), lowercase hex (LocalSend compares case-insensitively).
        XCTAssertEqual(a.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Set(dtos.map(\.id)).count, 2, "ids are unique")
        XCTAssertEqual(Set(refs.map(\.id)), Set(dtos.map(\.id)))
    }

    func testTwoTextItemsAreNotAMessage() throws {
        let (dtos, refs) = try SendEngine().describe([.text("one"), .text("two")])
        XCTAssertEqual(dtos.count, 2)
        XCTAssertEqual(refs.count, 2)
        XCTAssertTrue(dtos.allSatisfy { $0.fileName == "Note.txt" && $0.preview == nil })
    }
}

final class LSErrorTests: XCTestCase {
    func testStatusMapping() {
        func name(_ e: LSError) -> String {
            switch e {
            case .pinRequired: return "pin"
            case .rejected: return "rejected"
            case .busy: return "busy"
            case .checksumMismatch: return "checksum"
            case .tooManyRequests: return "429"
            case .badStatus(let c, _): return "bad\(c)"
            default: return "other"
            }
        }
        XCTAssertEqual(name(LSError.from(status: 401, body: "")), "pin")
        XCTAssertEqual(name(LSError.from(status: 403, body: "")), "rejected")
        XCTAssertEqual(name(LSError.from(status: 409, body: "")), "busy")
        XCTAssertEqual(name(LSError.from(status: 422, body: "")), "checksum")
        XCTAssertEqual(name(LSError.from(status: 429, body: "")), "429")
        XCTAssertEqual(name(LSError.from(status: 500, body: "boom")), "bad500")
    }

    func testBadStatusKeepsBody() {
        guard case .badStatus(let code, let body) = LSError.from(status: 418, body: "teapot") else { return XCTFail() }
        XCTAssertEqual(code, 418)
        XCTAssertEqual(body, "teapot")
    }

    func testEveryUserFacingErrorIsOneActionableLine() {
        let all: [LSError] = [
            .unreachable("PC"), .pcNotAnswering(alias: "TEMPEST", host: "172.20.10.228"), .fingerprintMismatch(expected: "A", got: "B"), .pinRequired, .rejected, .busy,
            .tooManyRequests, .checksumMismatch, .badStatus(500, "x"), .noClientIdentity,
        ]
        for e in all {
            let text = e.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(e)")
            XCTAssertFalse(text.contains("\n"), "\(e)")
        }
    }

    func testDeclinedMessageCoversTheThirtySecondTimeout() {
        // Grasp for Windows answers an unanswered prompt with 403 after 30s; the same case reads "declined".
        XCTAssertTrue(LSError.from(status: 403, body: "").errorDescription!.contains("30 seconds"))
    }
}

final class ScanTargetsTests: XCTestCase {
    private func v4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
    private let m24: UInt32 = 0xFFFF_FF00, m20: UInt32 = 0xFFFF_F000

    func testSlash24IsTheOldBehaviour() {
        let t = Discovery.scanTargets(ip: v4(192, 168, 1, 42), mask: m24)
        XCTAssertEqual(t.count, 253)                       // 254 hosts minus ourselves
        XCTAssertFalse(t.contains("192.168.1.42"))
        XCTAssertFalse(t.contains("192.168.1.0")); XCTAssertFalse(t.contains("192.168.1.255"))
        XCTAssertEqual(t.first, "192.168.1.1")
    }

    func testWiderSubnetOnlySweepsOwnSlash24() {
        // Phone 172.20.0.68 on a /20 (owner's WPA2-Enterprise network). A wider sweep got the phone kicked off
        // the Wi-Fi, so only the own /24 is probed; the PC at 172.20.10.228 is reached by its stored IP instead.
        let t = Discovery.scanTargets(ip: v4(172, 20, 0, 68), mask: m20)
        XCTAssertEqual(t.count, 254)                       // .0 is the /20's network address; .255 is a real host
        XCTAssertTrue(t.allSatisfy { $0.hasPrefix("172.20.0.") })
        XCTAssertTrue(t.contains("172.20.0.255"))
        XCTAssertFalse(t.contains("172.20.0.0")); XCTAssertFalse(t.contains("172.20.0.68"))
        XCTAssertFalse(t.contains("172.20.10.228"))
        XCTAssertEqual(Set(t).count, t.count, "no duplicates")
    }

    func testVeryWideSubnetIsStillOneSlash24() {
        let t = Discovery.scanTargets(ip: v4(10, 1, 7, 9), mask: 0xFFFF_0000)   // /16
        XCTAssertEqual(t.count, 255)
        XCTAssertTrue(t.allSatisfy { $0.hasPrefix("10.1.7.") })
    }

    func testSmallHotspotSubnet() {
        let t = Discovery.scanTargets(ip: v4(172, 20, 10, 2), mask: 0xFFFF_FFF0)   // iPhone hotspot /28
        XCTAssertEqual(t.count, 13)
        XCTAssertTrue(t.allSatisfy { $0.hasPrefix("172.20.10.") })
    }

    func testNothingToScanOnATinySubnet() {
        XCTAssertTrue(Discovery.scanTargets(ip: v4(10, 0, 0, 1), mask: 0xFFFF_FFFE).isEmpty)
    }
}

final class CodePairingTests: XCTestCase {
    func testGraspFieldMarksCodePairing() throws {
        let grasp = try JSONDecoder().decode(LSDeviceInfo.self, from: Data(#"{"alias":"TEMPEST","version":"2.2","grasp":1}"#.utf8))
        XCTAssertTrue(grasp.supportsCodePairing)
        let stock = try JSONDecoder().decode(LSDeviceInfo.self, from: Data(#"{"alias":"LocalSend","version":"2.2"}"#.utf8))
        XCTAssertFalse(stock.supportsCodePairing, "stock LocalSend keeps trust-on-first-use pairing")
    }

    func testPairingStatusMapping() {
        guard case .wrongCode(let left) = LSError.fromPairing(status: 401, body: Data(#"{"message":"Wrong code","attemptsLeft":3}"#.utf8))
        else { return XCTFail() }
        XCTAssertEqual(left, 3)
        guard case .pairingNotOpen = LSError.fromPairing(status: 409, body: Data()) else { return XCTFail() }
        guard case .pairingLocked = LSError.fromPairing(status: 429, body: Data()) else { return XCTFail() }
        guard case .badStatus(500, _) = LSError.fromPairing(status: 500, body: Data()) else { return XCTFail() }
        XCTAssertEqual(LSError.wrongCode(attemptsLeft: 1).errorDescription, "Wrong code. 1 try left.")
        XCTAssertEqual(LSError.wrongCode(attemptsLeft: 4).errorDescription, "Wrong code. 4 tries left.")
    }
}

final class FileNameTests: XCTestCase {
    private let tmp = URL(fileURLWithPath: "/tmp/.com.apple.Foundation.NSItemProvider.abc/temp7F3A.webp")
    private let now = Date(timeIntervalSince1970: 1_791_984_000)

    func testSuggestedNameWins() {
        XCTAssertEqual(PayloadBuilder.fileName(suggested: "IMG_0001", tmp: tmp, isImage: true), "IMG_0001.webp")
        XCTAssertEqual(PayloadBuilder.fileName(suggested: "Report.pdf", tmp: tmp, isImage: false), "Report.pdf")
    }

    func testNoSuggestedNameGetsAReadableOneNotTheTempName() {
        let name = PayloadBuilder.fileName(suggested: nil, tmp: tmp, isImage: true, now: now)
        XCTAssertTrue(name.hasPrefix("Photo 20"), name)
        XCTAssertTrue(name.hasSuffix(".webp"), name)
        XCTAssertFalse(name.contains("temp"), name)
        XCTAssertTrue(PayloadBuilder.fileName(suggested: "  ", tmp: tmp, isImage: false, now: now).hasPrefix("File 20"))
    }
}

final class ZipFolderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func folder(_ name: String) throws -> URL {
        let folder = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("sub/b.txt"))
        return folder
    }

    func testFolderBecomesZipAndOriginalIsKept() throws {
        let src = try folder("Trip")
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let zip = try PayloadBuilder.zipIfDirectory(src, workDir: out)
        XCTAssertEqual(zip.lastPathComponent, "Trip.zip")
        XCTAssertEqual(try Data(contentsOf: zip).prefix(2), Data("PK".utf8))   // zip local-file magic
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("sub/b.txt").path))
        guard case .file(_, let name, let mime, _) = PayloadBuilder.fileItem(zip) else { return XCTFail() }
        XCTAssertEqual(name, "Trip.zip")
        XCTAssertEqual(mime, "application/zip")
    }

    func testSuggestedNameWinsAndClashesGetANumber() throws {
        let src = try folder("tmp-123")
        let first = try PayloadBuilder.zipIfDirectory(src, name: "Trip", workDir: dir)
        let second = try PayloadBuilder.zipIfDirectory(src, name: "Trip", workDir: dir)
        XCTAssertEqual(first.lastPathComponent, "Trip.zip")
        XCTAssertEqual(second.lastPathComponent, "Trip 1.zip")
    }

    func testFileURLToAFolderIsZippedInPlace() throws {
        let src = try folder("Misc")
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sent = try PayloadBuilder.copyOrZip(src, workDir: out)
        XCTAssertEqual(sent.lastPathComponent, "Misc.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
    }

    func testFileURLToAFileIsCopiedUnderItsOwnName() throws {
        let src = dir.appendingPathComponent("Report.pdf")
        try Data("%PDF".utf8).write(to: src)
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sent = try PayloadBuilder.copyOrZip(src, workDir: out)
        XCTAssertEqual(sent.lastPathComponent, "Report.pdf")
        XCTAssertEqual(try Data(contentsOf: sent), Data("%PDF".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))   // original untouched
    }

    func testPlainFilePassesThroughUntouched() throws {
        let file = dir.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(try PayloadBuilder.zipIfDirectory(file, workDir: dir), file)
    }
}

final class SendSettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "grasp-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suite) }

    func testFreshDefaultsMatchTodaysBehaviour() {
        let s = SendSettings.load(from: defaults)
        XCTAssertEqual(s, .defaults)
        XCTAssertEqual(s.photoFormat, .jpg)
        XCTAssertTrue(s.textAsMessage)
        XCTAssertEqual(s.folderMode, .zip)
        XCTAssertFalse(s.stripLocation)
    }

    func testSaveLoadRoundTripAndQualityIsClamped() {
        var s = SendSettings()
        s.photoFormat = .original; s.jpegQuality = 0.7; s.stripLocation = true
        s.namePhotosByDate = true; s.textAsMessage = false; s.folderMode = .files
        s.save(to: defaults)
        XCTAssertEqual(SendSettings.load(from: defaults), s)

        defaults.set(5.0, forKey: "settings.jpegQuality")
        XCTAssertEqual(SendSettings.load(from: defaults).jpegQuality, 1)
    }
}

@MainActor
final class SettingsBehaviourTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grasp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func heic(_ name: String) throws -> URL {
        let src = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "heic"))
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    /// A JPG with a GPS block, made from the HEIC fixture.
    private func jpgWithLocation() throws -> URL {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(try heic("src.heic") as CFURL, nil))
        let out = dir.appendingPathComponent("located.jpg")
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImageFromSource(dst, src, 0, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        XCTAssertNotNil(gpsBlock(out), "fixture should carry GPS")
        return out
    }

    private func gpsBlock(_ url: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    }

    func testOriginalFormatKeepsHEIC() throws {
        var s = SendSettings(); s.photoFormat = .original
        guard case .file(let url, let name, _, _) = try PayloadBuilder.processPhoto(try heic("IMG_1.heic"), settings: s)
        else { return XCTFail() }
        XCTAssertEqual(name, "IMG_1.heic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoveLocationStripsGPSAndKeepsTheName() throws {
        let jpg = try jpgWithLocation()
        var s = SendSettings(); s.stripLocation = true
        guard case .file(let url, let name, _, _) = try PayloadBuilder.processPhoto(jpg, settings: s)
        else { return XCTFail() }
        XCTAssertEqual(name, "located.jpg")
        XCTAssertNil(gpsBlock(url))
    }

    func testNameByDateRenamesAndKeepsExtension() throws {
        var s = SendSettings(); s.namePhotosByDate = true
        guard case .file(_, let name, _, _) = try PayloadBuilder.processPhoto(try heic("IMG_2.heic"), settings: s)
        else { return XCTFail() }
        XCTAssertTrue(name.hasPrefix("Photo "), name)
        XCTAssertTrue(name.hasSuffix(".jpg"), name)   // converted first, then named
    }

    func testTextAsMessageOffSendsNoteTxt() throws {
        let (dtos, refs) = try SendEngine().describe([.text("https://example.com/")], textAsMessage: false)
        XCTAssertEqual(dtos.count, 1)
        XCTAssertEqual(dtos[0].fileName, "Note.txt")
        XCTAssertNil(dtos[0].preview)
        XCTAssertEqual(refs.count, 1)
    }

    func testFolderAsSeparateFilesIsFlattenedWithNumberedClashes() throws {
        let folder = dir.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("day2"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("2".utf8).write(to: folder.appendingPathComponent("day2/notes.txt"))
        try Data("h".utf8).write(to: folder.appendingPathComponent(".hidden"))
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let files = try PayloadBuilder.pack(folder, name: nil, workDir: out, mode: .files)
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["notes 1.txt", "notes.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("day2/notes.txt").path))
    }
}
