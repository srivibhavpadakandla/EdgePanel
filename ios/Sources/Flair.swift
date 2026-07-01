import SwiftUI

// Reusable "flair": the abstract living background, animated numbers, the usage ring, and the
// scroll/entrance motion the dashboard is built from. Kept out of App.swift so the screens stay
// readable and the motion primitives are shared.

// MARK: - Abstract living background

/// A slow, softly-drifting aurora of blurred colour blobs over the near-black base, so the app is
/// never a flat empty void. Honours Reduce Motion (renders a still frame). Cheap: 3 radial fills
/// on a Canvas at ~24fps.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tint: Color = T.accent
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0 : tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let w = size.width, h = size.height
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(T.bg))
                let blobs: [(Color, Double, Double, Double, Double)] = [
                    (tint,     0.30, 0.22, 0.062, 0.041),   // color, baseX%, baseY%, speedX, speedY
                    (T.green,  0.78, 0.30, 0.045, 0.055),
                    (T.accent2,0.55, 0.80, 0.052, 0.038),
                    (tint,     0.18, 0.72, 0.037, 0.048),
                ]
                for (i, b) in blobs.enumerated() {
                    let ph = Double(i) * 1.7
                    let cx = w * (b.1 + 0.13 * sin(t * b.3 + ph))
                    let cy = h * (b.2 + 0.11 * cos(t * b.4 + ph))
                    let r = w * 0.62
                    let center = CGPoint(x: cx, y: cy)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                        with: .radialGradient(
                            Gradient(colors: [b.0.opacity(0.40), b.0.opacity(0.15), .clear]),
                            center: center, startRadius: 0, endRadius: r))
                }
            }
            .blur(radius: 40)
            .overlay(
                // A light grounding vignette so the corners settle without killing the colour.
                RadialGradient(colors: [.clear, T.bg.opacity(0.32)], center: .center,
                               startRadius: 180, endRadius: 560)
            )
        }
        .ignoresSafeArea()
        .drawingGroup()
    }
}

// MARK: - Animated number

/// A number that counts up from 0 on appear and smoothly rolls to any new value. `format` turns the
/// interpolated Double into the displayed string (percent, tokens, dollars…).
struct CountUp: View {
    let value: Double
    var format: (Double) -> String = { "\(Int($0.rounded()))" }
    var font: Font = .claude(46, .bold)
    var color: Color = T.text
    @State private var v = 0.0
    var body: some View {
        _AnimNum(value: v, format: format, font: font, color: color)
            .onAppear { withAnimation(.easeOut(duration: 1.0)) { v = value } }
            .onChange(of: value) { _, nv in withAnimation(.easeOut(duration: 0.55)) { v = nv } }
    }
}
private struct _AnimNum: View, Animatable {
    var value: Double
    var format: (Double) -> String
    var font: Font
    var color: Color
    var animatableData: Double { get { value } set { value = newValue } }
    var body: some View { Text(format(value)).font(font).foregroundColor(color).monospacedDigit() }
}

// MARK: - Usage ring

/// A circular gauge — the dashboard's hero. Gradient stroke, soft glow, animated fill, and a
/// count-up number in the middle. Gently breathes when it's in the danger zone.
struct UsageRing: View {
    let frac: Double
    let label: String
    var size: CGFloat = 150
    var lineWidth: CGFloat = 14
    let color: Color
    var caption: String? = nil
    @State private var anim = 0.0
    @State private var breathe = false
    private var clamped: Double { min(max(frac, 0), 1) }
    var body: some View {
        ZStack {
            Circle().stroke(T.track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: anim)
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [color.opacity(0.55), color, color.opacity(0.9)]),
                                    center: .center, startAngle: .degrees(-90), endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.55), radius: 9)
            // Leading dot on the fill head for a bit of life.
            if clamped > 0.02 {
                Circle().fill(color).frame(width: lineWidth * 0.9, height: lineWidth * 0.9)
                    .shadow(color: color.opacity(0.8), radius: 5)
                    .offset(y: -(size - lineWidth) / 2)
                    .rotationEffect(.degrees(360 * anim))
            }
            VStack(spacing: 1) {
                CountUp(value: clamped * 100, format: { "\(Int($0.rounded()))" },
                        font: .claude(size * 0.28, .bold), color: T.text)
                Text(label).font(.claude(size * 0.075, .semibold)).tracking(1).foregroundColor(T.subtext)
                if let caption { Text(caption).font(.claude(size * 0.07)).foregroundColor(color.opacity(0.9)) }
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(breathe ? 1.015 : 1.0)
        .onAppear {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.78)) { anim = clamped }
            if clamped >= 0.8 {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
            }
        }
        .onChange(of: frac) { _, _ in withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) { anim = clamped } }
    }
}

// MARK: - Section header + stat chip

/// A section divider: small icon, tracked label, and a gradient hairline that trails off.
struct SectionHeader: View {
    let title: String
    var icon: String? = nil
    var tint: Color = T.subtext
    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(tint)
            }
            Text(title.uppercased()).font(.claude(11, .semibold)).tracking(1.4).foregroundColor(T.subtext)
            Rectangle()
                .fill(LinearGradient(colors: [T.border, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
        .padding(.top, 2)
    }
}

/// A compact glowing stat pill — icon, big value, small caption — for the hero satellites.
struct StatChip: View {
    let icon: String
    let value: String
    let caption: String
    var tint: Color = T.accent
    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.16)).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.claude(15, .bold)).foregroundColor(T.text).monospacedDigit()
                Text(caption).font(.claude(10)).foregroundColor(T.subtext).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.border, lineWidth: 1))
    }
}

// MARK: - Motion modifiers

extension View {
    /// Scroll-driven flair: cards scale/fade/blur slightly as they enter and leave the viewport,
    /// so scrolling feels alive instead of a rigid list.
    func scrollFlair() -> some View {
        scrollTransition(.interactive(timingCurve: .easeInOut)) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.4)
                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                .blur(radius: phase.isIdentity ? 0 : 2.5)
                .offset(y: phase.value * 6)
        }
    }

    /// Staggered entrance: fade + rise + de-blur, delayed by position so the dashboard assembles
    /// itself top-to-bottom on first paint.
    func appearIn(_ index: Int) -> some View { modifier(AppearIn(delay: Double(index) * 0.06)) }

    /// A tactile press: springs down slightly and fires a soft haptic when tapped.
    func pressable(_ action: @escaping () -> Void) -> some View { modifier(Pressable(action: action)) }
}

struct AppearIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 22)
            .blur(radius: shown ? 0 : 7)
            .onAppear { withAnimation(.spring(response: 0.62, dampingFraction: 0.85).delay(delay)) { shown = true } }
    }
}

struct Pressable: ViewModifier {
    let action: () -> Void
    @State private var down = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(down ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: down)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 30, pressing: { p in down = p }, perform: action)
            .sensoryFeedback(.impact(weight: .light), trigger: down) { _, now in now }
    }
}
