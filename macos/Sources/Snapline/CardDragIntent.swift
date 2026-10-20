import Foundation

/// Separate a small hand tremor, a deliberate horizontal rearrangement, and
/// pulling a card into another app. Distances are screen points, not pixels.
enum CardDragIntent: Equatable {
    case waiting, slide, export

    static let activationDistance: CGFloat = 4
    static let slideEscapeDistance: CGFloat = 8

    static func resolve(dx: CGFloat, dy: CGFloat, sliding: Bool) -> Self {
        if sliding {
            return abs(dy) >= slideEscapeDistance ? .export : .slide
        }
        guard hypot(dx, dy) >= activationDistance else { return .waiting }
        // Only a clearly horizontal motion stays on the rope. Diagonal pulls
        // should reach the destination app without first rearranging cards.
        if abs(dy) < activationDistance, abs(dx) >= abs(dy) * 2 { return .slide }
        return .export
    }
}
