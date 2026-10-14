import AppKit

/// Sticky notes. A note is a small picture of coloured paper with your words
/// on it, written into Snapline's own folder, so it hangs, swings, copies and
/// drags out exactly like a screenshot. What it says and what colour it is
/// live in the settings, so it can be edited again.
enum Notes {
    static let colors = ["yellow", "pink", "blue", "green", "orange"]

    static func paper(_ key: String) -> NSColor {
        switch key {
        case "pink": return NSColor(red: 0.98, green: 0.77, blue: 0.84, alpha: 1)
        case "blue": return NSColor(red: 0.75, green: 0.86, blue: 0.98, alpha: 1)
        case "green": return NSColor(red: 0.79, green: 0.92, blue: 0.78, alpha: 1)
        case "orange": return NSColor(red: 1.0, green: 0.84, blue: 0.64, alpha: 1)
        default: return NSColor(red: 1.0, green: 0.95, blue: 0.56, alpha: 1)
        }
    }

    static func isNote(_ url: URL) -> Bool { Settings.current.notes[url.path] != nil }
    static func get(_ url: URL) -> Settings.NoteData? { Settings.current.notes[url.path] }

    /// A fresh note of the given colour. Returns its picture.
    static func create(color: String, text: String = "", in folder: URL = Inbox.folder) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = formatter.string(from: Date())
        var url = folder.appendingPathComponent("Note \(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Note \(stamp) (\(n)).png")
            n += 1
        }
        let data = Settings.NoteData(text: text, color: color)
        Settings.current.notes[url.path] = data
        render(data, to: url)
        Settings.save()
        return url
    }

    /// New words or a new colour: the picture is drawn again.
    static func update(_ url: URL, text: String, color: String) {
        let data = Settings.NoteData(text: text, color: color)
        Settings.current.notes[url.path] = data
        render(data, to: url)
        Settings.save()
    }

    static func forget(_ url: URL) {
        if Settings.current.notes.removeValue(forKey: url.path) != nil { Settings.save() }
    }

    private static let w: CGFloat = 360, h: CGFloat = 270, curl: CGFloat = 48

    /// Coloured paper with a lifted corner and the words on it, drawn at twice the size for crisp text.
    static func render(_ note: Settings.NoteData, to url: URL) {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.current = ctx
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // AppKit draws with the origin at the bottom; flip so the layout reads top down.
        ctx.cgContext.translateBy(x: 0, y: h)
        ctx.cgContext.scaleBy(x: 1, y: -1)

        let paper = paper(note.color)
        let sheet = NSBezierPath()
        sheet.move(to: NSPoint(x: 0, y: 0))
        sheet.line(to: NSPoint(x: w, y: 0))
        sheet.line(to: NSPoint(x: w, y: h - curl))
        sheet.line(to: NSPoint(x: w - curl, y: h))
        sheet.line(to: NSPoint(x: 0, y: h))
        sheet.close()
        NSGradient(starting: paper.blended(withFraction: 0.12, of: .white) ?? paper, ending: paper.blended(withFraction: 0.08, of: .black) ?? paper)?
            .draw(in: sheet, angle: 90)
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: 34)).fill()

        // The curl: the back of the paper, lighter, with a shadow under it.
        let curlPath = NSBezierPath()
        curlPath.move(to: NSPoint(x: w, y: h - curl))
        curlPath.curve(to: NSPoint(x: w - curl, y: h), controlPoint1: NSPoint(x: w - curl * 0.15, y: h - curl * 0.15), controlPoint2: NSPoint(x: w - curl * 0.55, y: h - curl * 0.05))
        curlPath.curve(to: NSPoint(x: w, y: h - curl), controlPoint1: NSPoint(x: w - curl * 0.3, y: h - curl * 0.45), controlPoint2: NSPoint(x: w - curl * 0.15, y: h - curl * 0.7))
        curlPath.close()
        ctx.cgContext.saveGState()
        ctx.cgContext.translateBy(x: -3, y: 3)
        NSColor.black.withAlphaComponent(0.22).setFill()
        curlPath.fill()
        ctx.cgContext.restoreGState()
        NSGradient(starting: paper.blended(withFraction: 0.45, of: .white) ?? paper, ending: paper)?.draw(in: curlPath, angle: 45)

        // The words. Text is drawn unflipped, so flip back around its own box.
        // The editable note retains the full text. Bound layout work for a
        // large copy; only the first few lines can fit on the paper anyway.
        let text = String(note.text.prefix(4000))
        let rtl = text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        let style = NSMutableParagraphStyle()
        style.alignment = rtl ? .right : .left
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24, weight: .regular),
            .foregroundColor: NSColor(red: 0.23, green: 0.19, blue: 0.12, alpha: 1),
            .paragraphStyle: style,
        ]
        let box = NSRect(x: 26, y: 30, width: w - 52, height: h - 60)
        ctx.cgContext.saveGState()
        ctx.cgContext.translateBy(x: 0, y: h)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        let flipped = NSRect(x: box.minX, y: h - box.maxY, width: box.width, height: box.height)
        (text as NSString).draw(with: flipped, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        ctx.cgContext.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
        }
    }
}
