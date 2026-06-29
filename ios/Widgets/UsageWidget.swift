import WidgetKit
import SwiftUI

private let olive = Color(.sRGB, red: 0x93/255, green: 0xA0/255, blue: 0x63/255, opacity: 1)
private let clay  = Color(.sRGB, red: 0xD9/255, green: 0x79/255, blue: 0x5E/255, opacity: 1)

struct UsageEntry: TimelineEntry {
    let date: Date
    let five: Double      // 5-hour usage %
    let week: Double
    let reset: Date?
    let hasData: Bool
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), five: 62, week: 41, reset: nil, hasData: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // The app reloads us whenever the % moves; this fallback refresh keeps it from going
        // stale if the app hasn't run for a while.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(900))))
    }
    private func current() -> UsageEntry {
        if let s = UsageShared.read() {
            return UsageEntry(date: Date(), five: s.five, week: s.week, reset: s.reset, hasData: true)
        }
        return UsageEntry(date: Date(), five: 0, week: 0, reset: nil, hasData: false)
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "EdgePanelUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Your Claude Code 5-hour usage at a glance.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: UsageEntry
    private var frac: Double { entry.five.isFinite ? min(max(entry.five / 100, 0), 1) : 0 }
    private var pct: Int { entry.five.isFinite ? Int(entry.five.rounded()) : 0 }   // never Int(inf/nan) → trap

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.hasData ? "Claude \(pct)% · 5h" : "Claude usage —")

        case .accessoryCircular:
            Gauge(value: frac) {
                Text("5h")
            } currentValueLabel: {
                Text(entry.hasData ? "\(pct)" : "—")
            }
            .gaugeStyle(.accessoryCircularCapacity)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("CLAUDE · 5-HOUR").font(.system(size: 11, weight: .semibold)).widgetAccentable()
                Text(entry.hasData ? "\(pct)% used" : "no data").font(.system(size: 17, weight: .bold))
                Gauge(value: frac) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
            }

        default: // systemSmall (Home Screen / StandBy)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "bird.fill").font(.system(size: 12)).foregroundColor(clay)
                    Text("Claude").font(.system(size: 13, weight: .semibold, design: .serif)).foregroundColor(.white)
                    Spacer()
                }
                Spacer(minLength: 0)
                Text(entry.hasData ? "\(pct)%" : "—")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(.white).minimumScaleFactor(0.6).lineLimit(1)
                Text("of your 5-hour limit").font(.system(size: 11)).foregroundColor(.gray)
                Gauge(value: frac) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity).tint(frac >= 0.9 ? clay : olive)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(.sRGB, red: 0x16/255, green: 0x15/255, blue: 0x0F/255, opacity: 1))
        }
    }
}
