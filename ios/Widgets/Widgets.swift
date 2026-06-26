import WidgetKit
import SwiftUI
import ActivityKit

@main
struct EdgePanelWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkingLiveActivity()
    }
}

private let olive = Color(.sRGB, red: 0x93/255, green: 0xA0/255, blue: 0x63/255, opacity: 1)
private let clay = Color(.sRGB, red: 0xD9/255, green: 0x79/255, blue: 0x5E/255, opacity: 1)

struct WorkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkingAttributes.self) { context in
            // Lock Screen / banner presentation.
            LockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color(.sRGB, red: 0x16/255, green: 0x15/255, blue: 0x0F/255, opacity: 1))
                .activitySystemActionForegroundColor(olive)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(s.done ? "Done" : (s.count > 1 ? "\(s.count) chats" : (s.primary?.project ?? "Working")),
                          systemImage: s.done ? "checkmark.circle.fill" : "bird.fill")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundColor(.white).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.done {
                        Label("done", systemImage: "checkmark.circle.fill").foregroundColor(olive)
                            .font(.system(size: 13, weight: .semibold))
                    } else if let p = s.primary {
                        Text(p.start, style: .timer)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(olive).monospacedDigit()
                            .frame(maxWidth: 64, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if s.done {
                        Text(s.doneDetail ?? "finished")
                            .font(.system(size: 13, design: .serif)).foregroundColor(.white.opacity(0.9))
                    } else if s.count <= 1, let p = s.primary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("“\(p.prompt)”").font(.system(size: 13, design: .serif))
                                .foregroundColor(.white.opacity(0.9)).lineLimit(2)
                            Text(p.tokens == 0 ? "starting…" : "\(fmtTok(p.tokens)) tokens this turn")
                                .font(.system(size: 11)).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(s.sessions.prefix(3)) { SessionRow(s: $0) }
                            if s.count > 3 {
                                Text("+\(s.count - 3) more running")
                                    .font(.system(size: 11)).foregroundColor(.gray)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                BirdBadge(state: s)
            } compactTrailing: {
                if s.done {
                    Image(systemName: "checkmark").foregroundColor(olive)
                } else if let p = s.primary {
                    Text(p.start, style: .timer)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(olive).monospacedDigit().frame(maxWidth: 52)
                }
            } minimal: {
                BirdBadge(state: s)
            }
            .keylineTint(clay)
        }
    }
}

/// Bird icon with a small count badge when more than one prompt is running.
private struct BirdBadge: View {
    let state: WorkingAttributes.ContentState
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: state.done ? "checkmark.circle.fill" : "bird.fill")
                .foregroundColor(state.done ? olive : clay)
            if !state.done && state.count > 1 {
                Text("\(state.count)")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.black)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(Circle().fill(olive))
                    .offset(x: 7, y: -7)
            }
        }
    }
}

/// One running prompt: project · prompt … timer · tokens.
private struct SessionRow: View {
    let s: WorkingAttributes.Line
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill").font(.system(size: 10)).foregroundColor(clay)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.project).font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundColor(.white).lineLimit(1)
                Text("“\(s.prompt)”").font(.system(size: 11, design: .serif))
                    .foregroundColor(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(s.start, style: .timer)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(olive).monospacedDigit().frame(maxWidth: 56, alignment: .trailing)
                Text(s.tokens == 0 ? "starting…" : "\(fmtTok(s.tokens)) tok")
                    .font(.system(size: 10)).foregroundColor(.gray)
            }
        }
    }
}

struct LockScreenView: View {
    let state: WorkingAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: state.done ? "checkmark.circle.fill" : "bird.fill")
                    .font(.system(size: 20)).foregroundColor(state.done ? olive : clay)
                Text(state.done ? "Done"
                     : (state.count > 1 ? "\(state.count) chats running" : (state.primary?.project ?? "Working")))
                    .font(.system(size: 15, weight: .semibold, design: .serif)).foregroundColor(.white).lineLimit(1)
                Spacer()
                if !state.done, let p = state.primary {
                    Text(p.start, style: .timer)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(olive).monospacedDigit().frame(maxWidth: 70, alignment: .trailing)
                }
            }
            if state.done {
                Text(state.doneDetail ?? "finished")
                    .font(.system(size: 13, design: .serif)).foregroundColor(.white.opacity(0.85))
            } else if state.count <= 1, let p = state.primary {
                Text("“\(p.prompt)”").font(.system(size: 13, design: .serif))
                    .foregroundColor(.white.opacity(0.85)).lineLimit(2)
                Text(p.tokens == 0 ? "starting…" : "\(fmtTok(p.tokens)) tokens this turn")
                    .font(.system(size: 11)).foregroundColor(.gray)
            } else {
                ForEach(state.sessions.prefix(3)) { SessionRow(s: $0) }
                if state.count > 3 {
                    Text("+\(state.count - 3) more running")
                        .font(.system(size: 11)).foregroundColor(.gray)
                }
            }
        }
    }
}

private func fmtTok(_ t: Int) -> String {
    if t >= 1_000_000 { return String(format: "%.2fM", Double(t) / 1_000_000) }
    if t >= 1_000 { return String(format: "%.1fK", Double(t) / 1_000) }
    return "\(t)"
}
