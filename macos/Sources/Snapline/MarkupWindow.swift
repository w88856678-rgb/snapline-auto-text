import AppKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// The screenshot, enlarged, with a pen in your hand. Ballpoint, highlighter,
/// circle, box, arrow, text and blur; undo and redo; every mark is saved into
/// the file as you go, and the untouched original is kept so you can always
/// go back.
@MainActor
enum MarkupWindow {
    private static var open: [URL: NSWindow] = [:]
    static var isEditing: Bool { !open.isEmpty }

    static func show(_ url: URL, line: Line) {
        if let w = open[url] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let image = NSImage(contentsOf: url), let px = pixelSize(url) else { NSSound.beep(); return }
        let model = MarkupModel(url: url, image: image, pixels: px, line: line)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let avail = screen.visibleFrame
        let maxW = avail.width * 0.86, maxH = avail.height * 0.86 - 60
        let scale = min(1, min(maxW / px.width, maxH / px.height))
        model.scale = max(scale, min(1, 360 / px.width))
        let size = NSSize(width: px.width * model.scale + 24, height: px.height * model.scale + 60)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) · \(L("Mark up"))"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = NSHostingController(rootView: MarkupView(model: model))
        window.center()
        open[url] = window
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.flush()
                open[url] = nil
                if let token { NotificationCenter.default.removeObserver(token) }
                token = nil
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum MarkTool: String, CaseIterable, Identifiable {
    case pen, highlighter, circle, box, arrow, text, blur
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .circle: return "circle"
        case .box: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .blur: return "square.grid.3x3.fill"
        }
    }
    var label: String {
        switch self {
        case .pen: return L("Pen")
        case .highlighter: return L("Highlighter")
        case .circle: return L("Circle")
        case .box: return L("Box")
        case .arrow: return L("Arrow")
        case .text: return L("Text")
        case .blur: return L("Blur")
        }
    }
}

/// One mark, in the picture's own pixels.
struct Mark: Identifiable {
    let id = UUID()
    let tool: MarkTool
    var points: [CGPoint] = []
    var from: CGPoint = .zero
    var to: CGPoint = .zero
    var color: Color
    var width: CGFloat
    var text: String = ""
}

@MainActor
final class MarkupModel: ObservableObject {
    let url: URL
    let image: NSImage
    let pixels: CGSize
    let line: Line
    var scale: CGFloat = 1

    @Published var tool: MarkTool = .pen
    @Published var colorIndex = 0
    @Published var size = 1
    @Published var marks: [Mark] = []
    @Published var live: Mark?
    @Published var status = ""
    @Published var textEntry: (at: CGPoint, text: String)? = nil
    private var redoStack: [Mark] = []
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    static let palette: [Color] = [
        Color(red: 0.90, green: 0.22, blue: 0.21), Color(red: 1.0, green: 0.76, blue: 0.03), Color(red: 0.12, green: 0.53, blue: 0.90),
        Color(red: 0.26, green: 0.63, blue: 0.28), Color(red: 0.07, green: 0.07, blue: 0.07), .white,
    ]

    init(url: URL, image: NSImage, pixels: CGSize, line: Line) {
        self.url = url; self.image = image; self.pixels = pixels; self.line = line
    }

    var color: Color { Self.palette[colorIndex] }
    /// Stroke width in picture pixels, so it looks the same whatever the window size.
    var strokeWidth: CGFloat { ([2.2, 4, 7][size]) / scale * max(0.6, min(1.6, 1 / scale)) }
    var fontSize: CGFloat { strokeWidth * 4.5 + 6 }
    var canUndo: Bool { !marks.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func commit(_ mark: Mark) {
        marks.append(mark)
        redoStack.removeAll()
        touched()
    }

    func undo() { guard let m = marks.popLast() else { return }; redoStack.append(m); touched() }
    func redo() { guard let m = redoStack.popLast() else { return }; marks.append(m); touched() }

    private func touched() {
        dirty = true
        status = ""
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { save() }
        }
    }

    func flush() { saveTask?.cancel(); save() }

    // MARK: Blur

    private var pixelatedCache: NSImage?
    /// The picture in coarse blocks, for hiding what should not be shared.
    var pixelated: NSImage? {
        if let p = pixelatedCache { return p }
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        let filter = CIFilter.pixellate()
        filter.inputImage = ci
        filter.center = CGPoint(x: pixels.width / 2, y: pixels.height / 2)
        filter.scale = Float(max(8, min(40, pixels.width / 96)))
        guard let out = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: out.cropped(to: ci.extent))
        let img = NSImage(size: NSSize(width: pixels.width, height: pixels.height))
        img.addRepresentation(rep)
        pixelatedCache = img
        return img
    }

    // MARK: Saving

    func save() {
        guard dirty else { return }
        do {
            try Originals.keep(url)
            let renderer = ImageRenderer(content: MarkupPage(model: self, forExport: true).frame(width: pixels.width, height: pixels.height))
            renderer.scale = 1
            guard let cg = renderer.cgImage, let data = Self.encode(cg, like: url) else { status = L("Could not save"); return }
            try data.write(to: url, options: .atomic)
            dirty = false
            status = L("Saved")
            line.reloadThumbnail(for: url)
        } catch {
            log.error("Could not save the markup: \(error.localizedDescription, privacy: .public)")
            status = L("Could not save")
        }
    }

    /// Encodes the picture in the file's own format (PNG, JPEG, HEIC or TIFF;
    /// anything else becomes PNG bytes) and keeps its resolution, so a Retina
    /// screenshot opens at the same size it did before.
    private static func encode(_ image: CGImage, like url: URL) -> Data? {
        let ext = url.pathExtension.lowercased()
        let type: CFString
        switch ext {
        case "jpg", "jpeg": type = "public.jpeg" as CFString
        case "heic", "heif": type = "public.heic" as CFString
        case "tif", "tiff": type = "public.tiff" as CFString
        default: type = "public.png" as CFString
        }
        var properties: [CFString: Any] = [:]
        if ext == "jpg" || ext == "jpeg" { properties[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        if ext == "heic" || ext == "heif" { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let dpi = meta[kCGImagePropertyDPIWidth] { properties[kCGImagePropertyDPIWidth] = dpi }
            if let dpi = meta[kCGImagePropertyDPIHeight] { properties[kCGImagePropertyDPIHeight] = dpi }
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func revert() {
        saveTask?.cancel()
        marks.removeAll(); redoStack.removeAll(); live = nil
        do {
            try Originals.revert(url)
            line.reloadThumbnail(for: url)
            dirty = false
            status = L("Back to the original")
        } catch {
            log.error("Could not revert: \(error.localizedDescription, privacy: .public)")
            status = L("Could not save")
        }
    }

    func copyResult() {
        flush()
        if let id = line.items.first(where: { $0.url == url })?.id { line.copy(id) }
        status = L("Copied")
    }
}

/// The picture with every mark on it, in picture pixels. Shown scaled in the
/// editor and rendered at full size for saving.
struct MarkupPage: View {
    @ObservedObject var model: MarkupModel
    var forExport = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: model.image).resizable().interpolation(.high)
            Canvas { context, _ in
                // Blurs go under everything else, so a circle around a hidden bit stays visible.
                for m in model.marks where m.tool == .blur { draw(m, in: &context) }
                if let l = model.live, l.tool == .blur { draw(l, in: &context) }
                for m in model.marks where m.tool != .blur { draw(m, in: &context) }
                if let l = model.live, l.tool != .blur { draw(l, in: &context) }
            }
        }
        .frame(width: model.pixels.width, height: model.pixels.height)
    }

    private func draw(_ m: Mark, in context: inout GraphicsContext) {
        let style = StrokeStyle(lineWidth: m.width, lineCap: .round, lineJoin: .round)
        switch m.tool {
        case .pen, .highlighter:
            guard m.points.count > 1 else {
                if let p = m.points.first { context.fill(Path(ellipseIn: CGRect(x: p.x - m.width / 2, y: p.y - m.width / 2, width: m.width, height: m.width)), with: .color(m.color)) }
                return
            }
            var path = Path()
            path.move(to: m.points[0])
            for i in 1..<m.points.count {
                let mid = CGPoint(x: (m.points[i - 1].x + m.points[i].x) / 2, y: (m.points[i - 1].y + m.points[i].y) / 2)
                path.addQuadCurve(to: mid, control: m.points[i - 1])
            }
            path.addLine(to: m.points[m.points.count - 1])
            if m.tool == .highlighter {
                var ctx = context
                ctx.blendMode = .multiply
                ctx.stroke(path, with: .color(m.color.opacity(0.45)), style: StrokeStyle(lineWidth: m.width * 4, lineCap: .square, lineJoin: .round))
            } else {
                context.stroke(path, with: .color(m.color), style: style)
            }
        case .circle:
            context.stroke(Path(ellipseIn: rect(m)), with: .color(m.color), style: style)
        case .box:
            context.stroke(Path(roundedRect: rect(m), cornerRadius: m.width), with: .color(m.color), style: style)
        case .arrow:
            var path = Path()
            path.move(to: m.from); path.addLine(to: m.to)
            let dx = m.to.x - m.from.x, dy = m.to.y - m.from.y
            let len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len
            let head = max(10, m.width * 4)
            path.move(to: m.to); path.addLine(to: CGPoint(x: m.to.x - ux * head - uy * head * 0.55, y: m.to.y - uy * head + ux * head * 0.55))
            path.move(to: m.to); path.addLine(to: CGPoint(x: m.to.x - ux * head + uy * head * 0.55, y: m.to.y - uy * head - ux * head * 0.55))
            context.stroke(path, with: .color(m.color), style: style)
        case .text:
            let fontSize = m.width * 4.5 + 6
            let text = Text(m.text).font(.system(size: fontSize, weight: .semibold)).foregroundColor(m.color)
            let resolved = context.resolve(text)
            let size = resolved.measure(in: CGSize(width: 10_000, height: 10_000))
            let origin = CGPoint(x: m.from.x, y: m.from.y - fontSize * 0.7)
            // A thin halo in the opposite tone keeps the words readable over anything.
            let halo = Color(nsColor: NSColor(m.color).brightnessComponentSafe > 0.5 ? .black : .white).opacity(0.65)
            for (ox, oy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
                let haloText = context.resolve(Text(m.text).font(.system(size: fontSize, weight: .semibold)).foregroundColor(halo))
                context.draw(haloText, in: CGRect(origin: CGPoint(x: origin.x + ox * m.width * 0.4, y: origin.y + oy * m.width * 0.4), size: size))
            }
            context.draw(resolved, in: CGRect(origin: origin, size: size))
        case .blur:
            let r = rect(m)
            guard r.width > 1, r.height > 1, let pixelated = model.pixelated else { return }
            var ctx = context
            ctx.clip(to: Path(r))
            ctx.draw(Image(nsImage: pixelated).interpolation(.none), in: CGRect(origin: .zero, size: model.pixels))
        }
    }

    private func rect(_ m: Mark) -> CGRect {
        CGRect(x: min(m.from.x, m.to.x), y: min(m.from.y, m.to.y), width: abs(m.to.x - m.from.x), height: abs(m.to.y - m.from.y))
    }
}

extension NSColor {
    var brightnessComponentSafe: CGFloat {
        guard let c = usingColorSpace(.deviceRGB) else { return 0 }
        return c.brightnessComponent
    }
}

struct MarkupView: View {
    @ObservedObject var model: MarkupModel
    @State private var entry = ""
    @FocusState private var entryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .topLeading) {
                MarkupPage(model: model)
                    .scaleEffect(model.scale, anchor: .topLeading)
                    .frame(width: model.pixels.width * model.scale, height: model.pixels.height * model.scale)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
                    .gesture(drawGesture)
                if let te = model.textEntry {
                    TextField(L("Text"), text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: max(12, model.fontSize * model.scale), weight: .semibold))
                        .frame(width: 260)
                        .focused($entryFocused)
                        .onSubmit { commitText(at: te.at) }
                        .onExitCommand { model.textEntry = nil; entry = "" }
                        .offset(x: te.at.x * model.scale, y: te.at.y * model.scale - 14)
                        .onAppear { entryFocused = true }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.layoutDirection, Localization.isRTL ? .rightToLeft : .leftToRight)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(MarkTool.allCases) { tool in
                Button { model.tool = tool; model.textEntry = nil } label: {
                    Image(systemName: tool.symbol).frame(width: 26, height: 24)
                }
                .buttonStyle(.borderless)
                .background(model.tool == tool ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .help(tool.label)
            }
            Divider().frame(height: 18)
            ForEach(Array(MarkupModel.palette.enumerated()), id: \.offset) { i, c in
                Circle().fill(c)
                    .overlay(Circle().stroke(model.colorIndex == i ? Color.accentColor : Color.black.opacity(0.25), lineWidth: model.colorIndex == i ? 2.5 : 1))
                    .frame(width: 18, height: 18)
                    .onTapGesture { model.colorIndex = i }
            }
            Divider().frame(height: 18)
            ForEach(0..<3, id: \.self) { s in
                Button { model.size = s } label: {
                    Circle().fill(Color.primary).frame(width: CGFloat(5 + s * 4), height: CGFloat(5 + s * 4)).frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .background(model.size == s ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            Divider().frame(height: 18)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.borderless).disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command).help(L("Undo"))
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.borderless).disabled(!model.canRedo).keyboardShortcut("z", modifiers: [.command, .shift]).help(L("Redo"))
            Spacer()
            Text(model.status).foregroundStyle(.secondary).font(.caption)
            Button(L("Revert to original")) { model.revert() }
            Button(L("Copy")) { model.copyResult() }.keyboardShortcut("c", modifiers: .command)
            Button(L("Done")) { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let p = CGPoint(x: value.location.x / model.scale, y: value.location.y / model.scale)
                let start = CGPoint(x: value.startLocation.x / model.scale, y: value.startLocation.y / model.scale)
                switch model.tool {
                case .text:
                    break
                case .pen, .highlighter:
                    if model.live == nil { model.live = Mark(tool: model.tool, points: [start], color: model.color, width: model.strokeWidth) }
                    model.live?.points.append(p)
                default:
                    if model.live == nil { model.live = Mark(tool: model.tool, from: start, to: p, color: model.color, width: model.strokeWidth) }
                    model.live?.to = p
                }
            }
            .onEnded { value in
                let p = CGPoint(x: value.location.x / model.scale, y: value.location.y / model.scale)
                if model.tool == .text {
                    model.textEntry = (at: p, text: "")
                    entry = ""
                    return
                }
                guard var mark = model.live else { return }
                model.live = nil
                if mark.tool == .pen || mark.tool == .highlighter {
                    if mark.points.count < 2 { mark.points.append(p) }
                } else if hypot(mark.to.x - mark.from.x, mark.to.y - mark.from.y) < 4 {
                    return
                }
                model.commit(mark)
            }
    }

    private func commitText(at: CGPoint) {
        let text = entry.trimmingCharacters(in: .whitespaces)
        model.textEntry = nil
        entry = ""
        guard !text.isEmpty else { return }
        model.commit(Mark(tool: .text, from: at, to: at, color: model.color, width: model.strokeWidth, text: text))
    }
}
