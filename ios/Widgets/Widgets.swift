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
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.project, systemImage: "bird.fill")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundColor(.white).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.done {
                        Label("done", systemImage: "checkmark.circle.fill").foregroundColor(olive)
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text(context.state.start, style: .timer)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(olive).monospacedDigit()
                            .frame(maxWidth: 64, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.done ? (context.state.doneDetail ?? "finished")
                                                 : "“\(context.state.prompt)”")
                            .font(.system(size: 13, design: .serif))
                            .foregroundColor(.white.opacity(0.9)).lineLimit(2)
                        if !context.state.done {
                            Text("\(fmtTok(context.state.tokens)) tokens this turn")
                                .font(.system(size: 11)).foregroundColor(.gray)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.done ? "checkmark.circle.fill" : "bird.fill")
                    .foregroundColor(context.state.done ? olive : clay)
            } compactTrailing: {
                if context.state.done {
                    Image(systemName: "checkmark").foregroundColor(olive)
                } else {
                    Text(context.state.start, style: .timer)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(olive).monospacedDigit().frame(maxWidth: 52)
                }
            } minimal: {
                Image(systemName: context.state.done ? "checkmark.circle.fill" : "bird.fill")
                    .foregroundColor(context.state.done ? olive : clay)
            }
            .keylineTint(clay)
        }
    }
}

struct LockScreenView: View {
    let state: WorkingAttributes.ContentState
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.done ? "checkmark.circle.fill" : "bird.fill")
                .font(.system(size: 22)).foregroundColor(state.done ? olive : clay)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(state.project).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundColor(.white)
                    Spacer()
                    if state.done {
                        Text("done").font(.system(size: 13, weight: .semibold)).foregroundColor(olive)
                    } else {
                        Text(state.start, style: .timer)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(olive).monospacedDigit().frame(maxWidth: 70, alignment: .trailing)
                    }
                }
                Text(state.done ? (state.doneDetail ?? "finished") : "“\(state.prompt)”")
                    .font(.system(size: 13, design: .serif)).foregroundColor(.white.opacity(0.85)).lineLimit(2)
                if !state.done {
                    Text("\(fmtTok(state.tokens)) tokens this turn").font(.system(size: 11)).foregroundColor(.gray)
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
