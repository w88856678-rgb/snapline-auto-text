import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 240
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5
    static let tagWidth: CGFloat = 34
    static let tagHeight: CGFloat = 26

    /// Keep cards readable; the twenty retained items are browsed in pages.
    static func pageSize(for width: CGFloat) -> Int {
        max(1, min(12, Int(max(0, width - 200) / spacing)))
    }

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(58, width * 0.036) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }

    /// The nearest free place to the middle, as a fraction of the width, for a new photo.
    static func freeSpot(taken: [Double], width: CGFloat) -> Double {
        guard width > 0 else { return 0.5 }
        let half = cardWidth / 2
        let takenX = taken.map { CGFloat($0) * width }
        for step in 0..<40 {
            for candidate in [width / 2 + CGFloat(step) * spacing, width / 2 - CGFloat(step) * spacing] {
                if candidate < half || candidate > width - half { continue }
                if takenX.allSatisfy({ abs($0 - candidate) >= spacing * 0.9 }) { return Double(candidate / width) }
            }
        }
        return 0.5
    }

    /// Where each live photo hangs: spread evenly, or where you put it.
    @MainActor
    static func positions(for line: Line, width: CGFloat) -> [UUID: CGFloat] {
        let live = line.visibleItems
        var result: [UUID: CGFloat] = [:]
        let half = cardWidth / 2
        let manual = live.map { min(max(CGFloat($0.spot ?? 0.5) * width, half), max(half, width - half)) }
        let sorted = manual.sorted()
        // A crowded page can leave fallback spots at the centre. When cards
        // are later removed, keep the remaining single page readable too.
        let coincident = zip(sorted, sorted.dropFirst()).contains { abs($0 - $1) < 1 }
        if Settings.current.autoArrange || line.pageCount > 1 || coincident || width <= 0 {
            for (i, item) in live.enumerated() { result[item.id] = x(index: i, count: live.count, width: width) }
            return result
        }
        for (item, x) in zip(live, manual) {
            result[item.id] = x
        }
        return result
    }
}

struct LineView: View {
    @ObservedObject var line: Line
    /// The pointer is over the rope: the cursor says it can be dragged.
    @State private var overRope = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let positions = Layout.positions(for: line, width: width)
            ZStack(alignment: .topLeading) {
                Rope(width: width)
                    .id(line.look)
                // The line needs its width to find a free place for a new photo.
                Color.clear.frame(width: 1, height: 1)
                    .onAppear { line.layoutWidth = width }
                    .onChange(of: width) { _, w in line.layoutWidth = w }

                if Settings.current.bows && width > 400 {
                    let color = Pegs.rope()
                    Bow(color: color).position(x: width * 0.055, y: Layout.ropeY(x: width * 0.055, width: width) + 1)
                    Bow(color: color, mirrored: true).position(x: width * 0.945, y: Layout.ropeY(x: width * 0.945, width: width) + 1)
                }

                if line.liveCount == 0 {
                    Hint()
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                // A small paper tag always hangs at the end of the line: the menu, within reach.
                MenuTag(line: line)
                    .position(x: width - 30, y: Layout.ropeY(x: width - 30, width: width) - Layout.pinAbove * 0.75 + (Layout.tagHeight + 20) / 2)

                if line.pageCount > 1 {
                    PageControls(line: line)
                        .position(x: width - 82, y: 90)
                }

                ForEach(line.visibleItems) { item in
                    let x = positions[item.id] ?? width / 2
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line, width: width)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: positions)
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

/// The menu remains at the end of the rope; page arrows sit just below it.
private struct PageControls: View {
    @ObservedObject var line: Line

    var body: some View {
        HStack(spacing: 3) {
            Button { line.showPage(line.pageIndex - 1) } label: {
                Image(systemName: "chevron.left").frame(width: 25, height: 30)
            }
            .disabled(line.pageIndex == 0)
            .accessibilityLabel("上一页 / Previous page")
            Text("\(line.pageIndex + 1)/\(line.pageCount)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 30)
                .accessibilityLabel("第 \(line.pageIndex + 1) 页，共 \(line.pageCount) 页")
            Button { line.showPage(line.pageIndex + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 25, height: 30)
            }
            .disabled(line.pageIndex + 1 >= line.pageCount)
            .accessibilityLabel("下一页 / Next page")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .background(.regularMaterial, in: Capsule())
        .help("左右翻页查看全部卡片 / Browse all cards")
        .background(GeometryReader { g in
            Color.clear.preference(key: HitRectsKey.self, value: [Self.id: g.frame(in: .global)])
        })
    }

    static let id = UUID()
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .onTapGesture { Capture.snip() }
            .background(GeometryReader { g in
                Color.clear.preference(key: HitRectsKey.self, value: [Hint.id: g.frame(in: .global)])
            })
    }
    static let id = UUID()
}

/// A yellow paper tag with a plus, pegged near the end of the line. Click it for the menu.
struct MenuTag: View {
    @ObservedObject var line: Line

    var body: some View {
        VStack(spacing: -7) {
            Peg(style: Settings.current.pegStyle, seed: 1).scaleEffect(0.75, anchor: .top).frame(height: 22).zIndex(1)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.96, blue: 0.63), Color(red: 0.95, green: 0.87, blue: 0.43)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Color.black.opacity(0.25), lineWidth: 0.6))
                .overlay(Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.35, green: 0.28, blue: 0.12)))
                .frame(width: Layout.tagWidth, height: Layout.tagHeight)
                .rotationEffect(.degrees(-4), anchor: .top)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { NotificationCenter.default.post(name: .snaplineMenuRequested, object: nil) }
        .help(L("Menu"))
        .background(GeometryReader { g in
            Color.clear.preference(key: HitRectsKey.self, value: [MenuTag.id: g.frame(in: .global)])
        })
    }
    static let id = UUID()
}

extension Notification.Name {
    static let snaplineMenuRequested = Notification.Name("snaplineMenuRequested")
}


/// A thin cord in the colour you chose, with a faint highlight and a soft
/// shadow, fading at both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        let color = Pegs.rope()
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(color, lineWidth: 1.6)
            path.stroke(color.lighter(0.55).opacity(0.7), lineWidth: 0.5).offset(y: -0.45)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Starts a new screenshot, the way Cmd+Shift+5 would.
enum Capture {
    static func snip() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-U"]
        try? task.run()
    }
}
