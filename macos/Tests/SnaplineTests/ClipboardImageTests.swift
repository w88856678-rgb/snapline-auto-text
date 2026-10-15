import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Snapline

final class ClipboardImageTests: XCTestCase {
    @MainActor
    private func encodedImage(type: UTType = .png, width: Int = 13, height: Int = 9,
                              color: (UInt8, UInt8, UInt8, UInt8) = (230, 70, 30, 255),
                              orientation: Int? = nil) throws -> Data {
        let bytes = Array(repeating: [color.0, color.1, color.2, color.3], count: width * height).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                         bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                         bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                         shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @MainActor
    private func setImage(_ data: Data, type: NSPasteboard.PasteboardType = .png,
                          on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(data, forType: type))
    }

    @MainActor
    private func inTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnaplineClipboardImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    func testPNGAndTIFFWithTheSamePixelsHaveTheSameFingerprint() async throws {
        try await MainActor.run {
            let png = try XCTUnwrap(ClipboardImage(data: encodedImage(type: .png)))
            let tiff = try XCTUnwrap(ClipboardImage(data: encodedImage(type: .tiff)))
            XCTAssertEqual(png.size, CGSize(width: 13, height: 9))
            XCTAssertEqual(png.fingerprint, tiff.fingerprint)
            XCTAssertEqual(png.fingerprint.count, 32)
        }
    }

    func testDifferentPicturesOfTheSameSizeAreNotDuplicates() async throws {
        try await MainActor.run {
            let red = try XCTUnwrap(ClipboardImage(data: encodedImage(color: (255, 0, 0, 255))))
            let blue = try XCTUnwrap(ClipboardImage(data: encodedImage(color: (0, 0, 255, 255))))
            XCTAssertEqual(red.size, blue.size)
            XCTAssertNotEqual(red.fingerprint, blue.fingerprint)
        }
    }

    func testImageDimensionsArePartOfTheFingerprint() async throws {
        try await MainActor.run {
            let wide = try XCTUnwrap(ClipboardImage(data: encodedImage(width: 6, height: 2)))
            let tall = try XCTUnwrap(ClipboardImage(data: encodedImage(width: 2, height: 6)))
            XCTAssertNotEqual(wide.fingerprint, tall.fingerprint)
        }
    }

    func testSmallTransparentImageKeepsPixelsAndResolution() async throws {
        try await MainActor.run {
            let image = try XCTUnwrap(ClipboardImage(data: encodedImage(width: 1, height: 1, color: (255, 0, 0, 128))))
            XCTAssertEqual(image.size, CGSize(width: 1, height: 1))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: image.png))
            XCTAssertEqual(rep.pixelsWide, 1)
            XCTAssertEqual(rep.pixelsHigh, 1)
            XCTAssertTrue(rep.hasAlpha)
            let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            XCTAssertTrue(abs(color.alphaComponent - 128.0 / 255.0) < 0.005)
            XCTAssertTrue(color.redComponent > 0.99)
            let roundTrip = try XCTUnwrap(ClipboardImage(data: image.png))
            XCTAssertEqual(image.fingerprint, roundTrip.fingerprint)
        }
    }

    func testJPEGOrientationIsAppliedToTheSavedImage() async throws {
        try await MainActor.run {
            let jpeg = try encodedImage(type: .jpeg, width: 24, height: 16, orientation: 6)
            let image = try XCTUnwrap(ClipboardImage(data: jpeg))
            XCTAssertEqual(image.size, CGSize(width: 16, height: 24))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: image.png))
            XCTAssertEqual(rep.pixelsWide, 16)
            XCTAssertEqual(rep.pixelsHigh, 24)
            let saved = try XCTUnwrap(ClipboardImage(data: image.png))
            XCTAssertEqual(image.fingerprint, saved.fingerprint)
        }
    }

    func testGIFBecomesAStaticPNG() async throws {
        try await MainActor.run {
            let image = try XCTUnwrap(ClipboardImage(data: encodedImage(type: .gif)))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(image.png as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            XCTAssertEqual(image.size, CGSize(width: 13, height: 9))
        }
    }

    func testCopiedImageWithHTMLURLAndCaptionStillProducesThePicture() async throws {
        try await MainActor.run {
            try withTestPasteboard { pasteboard in
                let data = try encodedImage()
                setImage(data, on: pasteboard)
                XCTAssertTrue(pasteboard.setString("<img src=\"https://example.com/photo.png\">", forType: .html))
                XCTAssertTrue(pasteboard.setString("https://example.com/photo.png", forType: .URL))
                XCTAssertTrue(pasteboard.setString("图片说明", forType: .string))
                let image = try XCTUnwrap(ClipboardImage.read(from: pasteboard))
                let original = try XCTUnwrap(ClipboardImage(data: data))
                XCTAssertEqual(image.fingerprint, original.fingerprint)
            }
        }
    }

    func testPNGIsPreferredWhenOtherRepresentationsDescribeDifferentPictures() async throws {
        try await MainActor.run {
            try withTestPasteboard { pasteboard in
                let png = try encodedImage(color: (0, 255, 0, 255))
                setImage(try encodedImage(type: .tiff, color: (0, 0, 255, 255)), type: .tiff, on: pasteboard)
                XCTAssertTrue(pasteboard.setData(png, forType: .png))
                let copied = try XCTUnwrap(ClipboardImage.read(from: pasteboard))
                let original = try XCTUnwrap(ClipboardImage(data: png))
                XCTAssertEqual(copied.fingerprint, original.fingerprint)
            }
        }
    }

    func testMalformedPNGCanFallBackToValidTIFF() async throws {
        try await MainActor.run {
            try withTestPasteboard { pasteboard in
                setImage(Data([0, 1, 2]), on: pasteboard)
                let tiff = try encodedImage(type: .tiff)
                XCTAssertTrue(pasteboard.setData(tiff, forType: .tiff))
                XCTAssertNotNil(ClipboardImage.read(from: pasteboard))
            }
        }
    }

    func testJPEGClipboardRepresentationIsSupported() async throws {
        try await MainActor.run {
            try withTestPasteboard { pasteboard in
                setImage(try encodedImage(type: .jpeg), type: .init(UTType.jpeg.identifier), on: pasteboard)
                XCTAssertEqual(ClipboardImage.read(from: pasteboard)?.size, CGSize(width: 13, height: 9))
            }
        }
    }

    func testFinderCopyOfOneLocalImageIsReadWithoutCreatingATextNote() async throws {
        try await MainActor.run {
            try inTemporaryFolder { folder in
                try withTestPasteboard { pasteboard in
                    let file = folder.appendingPathComponent("办公图片.png")
                    try encodedImage().write(to: file)
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.writeObjects([file as NSURL]))
                    XCTAssertFalse(ClipboardContent.shouldIgnoreImages(pasteboard))
                    XCTAssertTrue(ClipboardContent.shouldIgnore(pasteboard))
                    XCTAssertNil(ClipboardContent.text(from: pasteboard))
                    XCTAssertEqual(ClipboardImage.read(from: pasteboard)?.size, CGSize(width: 13, height: 9))
                }
            }
        }
    }

    func testMultiFileCopiesAreIgnored() async throws {
        try await MainActor.run {
            try inTemporaryFolder { folder in
                try withTestPasteboard { pasteboard in
                    let first = folder.appendingPathComponent("one.png")
                    let second = folder.appendingPathComponent("two.png")
                    try encodedImage().write(to: first)
                    try encodedImage().write(to: second)
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL]))
                    XCTAssertNil(ClipboardImage.read(from: pasteboard))
                }
            }
        }
    }

    func testFinderOriginalTakesPrecedenceOverItsSmallerPreview() async throws {
        try await MainActor.run {
            try inTemporaryFolder { folder in
                try withTestPasteboard { pasteboard in
                    let file = folder.appendingPathComponent("original.png")
                    try encodedImage(width: 31, height: 27).write(to: file)
                    let item = NSPasteboardItem()
                    XCTAssertTrue(item.setString(file.absoluteString, forType: .fileURL))
                    let preview = try encodedImage(width: 3, height: 2)
                    XCTAssertTrue(item.setData(preview, forType: .png))
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.writeObjects([item]))
                    XCTAssertEqual(ClipboardImage.read(from: pasteboard)?.size, CGSize(width: 31, height: 27))
                }
            }
        }
    }

    func testOrdinaryFinderFileDoesNotBecomeItsPreviewImage() async throws {
        try await MainActor.run {
            try inTemporaryFolder { folder in
                try withTestPasteboard { pasteboard in
                    let file = folder.appendingPathComponent("report.txt")
                    try Data("ordinary document".utf8).write(to: file)
                    let item = NSPasteboardItem()
                    XCTAssertTrue(item.setString(file.absoluteString, forType: .fileURL))
                    let preview = try encodedImage()
                    XCTAssertTrue(item.setData(preview, forType: .png))
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.writeObjects([item]))
                    XCTAssertNil(ClipboardImage.read(from: pasteboard))
                }
            }
        }
    }

    func testAdvertisedImageCanBeDistinguishedFromAnOrdinaryURL() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("https://example.com/photo.png", forType: .URL))
                XCTAssertFalse(ClipboardImage.hasImageRepresentation(pasteboard))
                XCTAssertTrue(pasteboard.setData(Data([0, 1, 2]), forType: .png))
                XCTAssertTrue(ClipboardImage.hasImageRepresentation(pasteboard))
                XCTAssertNil(ClipboardImage.read(from: pasteboard))
            }
        }
    }

    func testOrdinaryFilesDirectoriesAndWebURLsAreNotPictures() async throws {
        try await MainActor.run {
            try inTemporaryFolder { folder in
                try withTestPasteboard { pasteboard in
                    let file = folder.appendingPathComponent("report.txt")
                    try Data("普通文件内容".utf8).write(to: file)
                    for url in [file, folder] {
                        pasteboard.clearContents()
                        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
                        XCTAssertNil(ClipboardImage.read(from: pasteboard))
                        XCTAssertNil(ClipboardContent.text(from: pasteboard))
                    }
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("https://example.com/photo.png", forType: .URL))
                    XCTAssertNil(ClipboardImage.read(from: pasteboard))
                    XCTAssertNil(ClipboardImage(contentsOf: URL(string: "https://example.com/photo.png")!))
                }
            }
        }
    }

    func testOwnAndPrivateImageCopiesAreIgnoredAcrossAllItems() async throws {
        try await MainActor.run {
            try withTestPasteboard { pasteboard in
                let data = try encodedImage()
                let markers: [NSPasteboard.PasteboardType] = [
                    ClipboardContent.ownCopyType, .init("org.nspasteboard.ConcealedType"),
                    .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.AutoGeneratedType"),
                ]
                for marker in markers {
                    let image = NSPasteboardItem()
                    XCTAssertTrue(image.setData(data, forType: .png))
                    let protected = NSPasteboardItem()
                    XCTAssertTrue(protected.setData(Data(), forType: marker))
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.writeObjects([image, protected]))
                    XCTAssertTrue(ClipboardContent.shouldIgnoreImages(pasteboard), marker.rawValue)
                    XCTAssertNil(ClipboardImage.read(from: pasteboard), marker.rawValue)
                }
            }
        }
    }

    func testEmptyMalformedAndNonImageDataAreIgnored() async {
        await MainActor.run {
            withTestPasteboard { pasteboard in
                for data in [Data(), Data([0, 0xff, 1]), Data("<html>not a picture</html>".utf8)] {
                    XCTAssertNil(ClipboardImage(data: data))
                    setImage(data, on: pasteboard)
                    XCTAssertNil(ClipboardImage.read(from: pasteboard))
                }
            }
        }
    }
}
