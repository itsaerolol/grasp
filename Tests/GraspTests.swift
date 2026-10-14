import XCTest
import CryptoKit
import UniformTypeIdentifiers

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
        guard case .file(let url, let name, let mime, let size) = try PayloadBuilder.convertIfHEIC(heic) else {
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
        guard case .file(_, let name, _, _) = try PayloadBuilder.convertIfHEIC(heic) else { return XCTFail() }
        XCTAssertEqual(name, "photo.jpg")
    }

    func testNonHEICPassesThroughUntouched() throws {
        let pdf = dir.appendingPathComponent("Report.pdf")
        try Data("%PDF-1.1".utf8).write(to: pdf)
        guard case .file(let url, let name, let mime, let size) = try PayloadBuilder.convertIfHEIC(pdf) else { return XCTFail() }
        XCTAssertEqual(url, pdf)
        XCTAssertEqual(name, "Report.pdf")
        XCTAssertEqual(mime, "application/pdf")
        XCTAssertEqual(size, 8)
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
            .unreachable("PC"), .fingerprintMismatch(expected: "A", got: "B"), .pinRequired, .rejected, .busy,
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

    func testSlash20CoversThePCFromTheReportedNetwork() {
        // Phone 172.20.0.68, PC 172.20.10.228, mask 255.255.240.0.
        let t = Discovery.scanTargets(ip: v4(172, 20, 0, 68), mask: m20)
        XCTAssertEqual(t.count, 4093)                      // 4094 hosts minus ourselves
        XCTAssertTrue(t.contains("172.20.10.228"))
        XCTAssertTrue(t.contains("172.20.15.254"))
        XCTAssertFalse(t.contains("172.20.0.68")); XCTAssertFalse(t.contains("172.20.0.0"))
        XCTAssertFalse(t.contains("172.20.15.255")); XCTAssertFalse(t.contains("172.20.16.1"))
        XCTAssertTrue(t.prefix(253).allSatisfy { $0.hasPrefix("172.20.0.") }, "own /24 is probed first")
        XCTAssertEqual(Set(t).count, t.count, "no duplicates")
    }

    func testWiderThanSlash20IsClampedToTheSlash20() {
        let t = Discovery.scanTargets(ip: v4(10, 1, 7, 9), mask: 0xFFFF_0000)   // /16
        XCTAssertLessThanOrEqual(t.count, 4094)
        XCTAssertTrue(t.allSatisfy { $0.hasPrefix("10.1.") })
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
