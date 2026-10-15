import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// An immutable copy of the image behind one clipboard change. All later
/// saving and duplicate checks use these bytes, never the current clipboard.
@MainActor
struct ClipboardImage {
    let png: Data
    let size: CGSize
    /// Dimensions and canonical sRGB RGBA pixels, independent of file format.
    let fingerprint: Data

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .image) == true else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // Decode the full resolution, first/primary frame. Image I/O applies
        // EXIF rotation and mirroring before we normalize its pixel storage.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              image.width <= Int.max / 4,
              image.height <= Int.max / (image.width * 4) else { return nil }
        let rowBytes = image.width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: space, bitmapInfo: bitmapInfo) else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data, let normalized = context.makeImage() else { return nil }

        var widthValue = UInt64(image.width).bigEndian
        var heightValue = UInt64(image.height).bigEndian
        var hash = SHA256()
        withUnsafeBytes(of: &widthValue) { hash.update(bufferPointer: $0) }
        withUnsafeBytes(of: &heightValue) { hash.update(bufferPointer: $0) }
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: pixels, count: rowBytes * image.height))

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, normalized, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        png = output as Data
        size = CGSize(width: image.width, height: image.height)
        fingerprint = Data(hash.finalize())
    }

    init?(contentsOf url: URL) {
        guard Self.isLocalFile(url),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    static func read(from pasteboard: NSPasteboard) -> ClipboardImage? {
        guard !ClipboardContent.shouldIgnoreImages(pasteboard) else { return nil }
        let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        // One Finder image is useful. A multi-file copy is a different action;
        // do not turn its preview or its first file into an unexpected card.
        guard fileURLs.count <= 1 else { return nil }
        // Finder may also advertise a thumbnail. Use the original local file
        // so its resolution survives, and never capture a PDF/file icon.
        if let file = fileURLs.first { return ClipboardImage(contentsOf: file) }

        // Read only advertised binary image representations. HTML, web URLs,
        // and captions alongside a browser's image copy do not replace it.
        for type in imageTypes(on: pasteboard) {
            if let data = pasteboard.data(forType: type), let image = ClipboardImage(data: data) {
                return image
            }
            for item in pasteboard.pasteboardItems ?? [] where item.types.contains(type) {
                if let data = item.data(forType: type), let image = ClipboardImage(data: data) {
                    return image
                }
            }
        }
        return nil
    }

    /// Recognize an image-copy action even when its binary data is damaged;
    /// callers should not hang its fallback URL or HTML caption as text.
    static func hasImageRepresentation(_ pasteboard: NSPasteboard) -> Bool {
        !imageTypes(on: pasteboard).isEmpty
    }

    private static func imageTypes(on pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let all = (pasteboard.types ?? []) + (pasteboard.pasteboardItems ?? []).flatMap(\.types)
        let preferred: [NSPasteboard.PasteboardType] = [.png, .tiff]
        var result = preferred.filter(all.contains)
        for type in all where !result.contains(type) && UTType(type.rawValue)?.conforms(to: .image) == true {
            result.append(type)
        }
        return result
    }

    private static func isLocalFile(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
    }
}
