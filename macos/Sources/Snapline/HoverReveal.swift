import AppKit

/// Only the top edge and a narrow band around the rope reveal the line.
/// Moving elsewhere in the upper half of a document must not open it.
enum HoverReveal {
    static func contains(_ point: CGPoint, screenFrame: CGRect, visibleFrame: CGRect,
                         menuBarHeight: CGFloat, lineOffset: Double) -> Bool {
        guard screenFrame.contains(point) else { return false }
        let topBand = max(1, menuBarHeight)
        if point.y >= screenFrame.maxY - topBand { return true }
        let offset = CGFloat(max(0, min(200, lineOffset)))
        let x = point.x - visibleFrame.minX
        guard x >= 0, x <= visibleFrame.width else { return false }
        let ropeY = visibleFrame.maxY - offset - Layout.ropeY(x: x, width: visibleFrame.width)
        return abs(point.y - ropeY) <= 14
    }
}
