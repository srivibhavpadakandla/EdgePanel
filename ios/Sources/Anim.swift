import SwiftUI

// Reusable, SUBTLE motion for the dashboard — layered onto the existing layout, not a redesign.
// One file so the animation vocabulary stays consistent as we add more.

enum Motion {
    static let entrance = Animation.spring(response: 0.5, dampingFraction: 0.86)
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.62)
    static let number = Animation.snappy(duration: 0.35)
}

extension View {
    /// Gentle staggered entrance: fade + a small rise, delayed by position so the dashboard
    /// assembles itself top-to-bottom on first paint. Fires once (onAppear), so it doesn't
    /// re-animate on every 1.5s poll.
    func appearIn(_ index: Int = 0) -> some View { modifier(AppearIn(delay: Double(index) * 0.05)) }

    /// Tactile press: scales down a hair + a light haptic while held. Uses a simultaneous gesture
    /// so it does NOT consume an existing `.onTapGesture` on the same view.
    func pressable() -> some View { modifier(Pressable()) }
}

private struct AppearIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear { withAnimation(Motion.entrance.delay(delay)) { shown = true } }
    }
}

private struct Pressable: ViewModifier {
    @GestureState private var down = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(down ? 0.98 : 1)
            .animation(Motion.press, value: down)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).updating($down) { _, s, _ in s = true }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: down) { _, isDown in isDown }
    }
}

/// A number that smoothly rolls (digit-by-digit) between values when it changes.
struct RollingInt: View {
    let value: Int
    var body: some View {
        Text("\(value)")
            .contentTransition(.numericText())
            .animation(Motion.number, value: value)
    }
}
