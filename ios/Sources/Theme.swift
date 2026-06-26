import SwiftUI

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}

enum T {  // EdgePanel dark theme (matches the macOS panel)
    static let bg = Color(hex: 0x16150F)
    static let card = Color(hex: 0x201F1C)
    static let accentSoft = Color(hex: 0x342A22)
    static let text = Color(hex: 0xF3EFE6)
    static let subtext = Color(hex: 0x9C968C)
    static let accent = Color(hex: 0xE08A6A)
    static let accent2 = Color(hex: 0xD9795E)
    static let border = Color.white.opacity(0.07)
    static let track = Color(hex: 0x2C2B27)
    static let green = Color(hex: 0x93A063)
    static let amber = Color(hex: 0xD9A24E)
    static let red = Color(hex: 0xD05A4E)
    static let heat = [Color(hex: 0x2C2B27), Color(hex: 0xB6CE8A), Color(hex: 0x88AC5A), Color(hex: 0x57813A), Color(hex: 0x2E5220)]
}

extension Font {
    static func claude(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w, design: .serif)
    }
}

func sevColor(_ f: Double) -> Color { f >= 0.8 ? T.red : f >= 0.5 ? T.amber : T.green }
func fmtPct(_ f: Double) -> String { "\(Int((min(max(f, 0), 1) * 100).rounded()))%" }
func fmtCost(_ c: Double) -> String {
    if c >= 1000 { return String(format: "$%.0f", c) }
    if c >= 100 { return String(format: "$%.1f", c) }
    return String(format: "$%.2f", c)
}
func fmtTokens(_ t: Int) -> String {
    if t >= 1_000_000 { return String(format: "%.2fM", Double(t) / 1_000_000) }
    if t >= 1_000 { return String(format: "%.1fK", Double(t) / 1_000) }
    return "\(t)"
}
func prettyModel(_ m: String?) -> String { m ?? "Claude" }

// A bordered card container.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(T.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(T.border, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.claude(11, .semibold)).tracking(0.8).foregroundColor(T.subtext)
    }
}
