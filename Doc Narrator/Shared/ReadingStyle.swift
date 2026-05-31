import SwiftUI

/// Comfortable reading typography for AI-generated text (summaries, chat).
/// A reader app's AI output should be easy to read on screen, not just narrated.
struct ReadingStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(.body, design: .rounded))
            .lineSpacing(6)
    }
}

extension View {
    func readingStyle() -> some View { modifier(ReadingStyle()) }
}
