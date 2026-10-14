import AppKit

/// A text note travels as its words, so chat editors do not prefer its PNG.
/// Regular photos keep the original file drag behaviour.
@MainActor
enum CardTransfer {
    static func textItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: ClipboardContent.ownCopyType)
        return item
    }

    static func dragWriter(for url: URL) -> NSPasteboardWriting {
        if let note = Notes.get(url) { return textItem(note.text) }
        return url as NSURL
    }
}
