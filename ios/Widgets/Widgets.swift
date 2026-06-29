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

// The countup timer self-ticks in the widget without the app being awake, so the
// activity stays accurate while a prompt runs even fully backgrounded. "Done" is
// delivered out-of-band (ntfy notification + reconcile when the app reopens), so
// we don't fake an "offline/stale" state here — that just made the Island look
// broken during normal backgrounded use.
struct WorkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkingAttributes.self) { context in
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
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if s.done {
                            Label("done", systemImage: "checkmark.circle.fill").foregroundColor(olive)
                                .font(.system(size: 13, weight: .semibold))
                        } else if let p = s.primary {
                            Text(timerInterval: p.start...p.freezeEnd, countsDown: false)
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(olive).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .frame(maxWidth: 62, alignment: .trailing)
                        }
                    }.padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Group {
                        if s.done {
                            Text(s.doneDetail ?? "finished")
                                .font(.system(size: 13, design: .serif)).foregroundColor(.white.opacity(0.9))
                        } else if s.count <= 1, let p = s.primary {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“\(p.prompt)”").font(.system(size: 13, design: .serif))
                                    .foregroundColor(.white.opacity(0.9)).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(p.tokens == 0 ? "starting…" : "\(fmtTok(p.tokens)) tokens this turn")
                                        .font(.system(size: 11)).foregroundColor(.gray)
                                    if let note = workNote(p) {
                                        Label(note, systemImage: "person.2.fill")
                                            .font(.system(size: 11, weight: .medium)).foregroundColor(olive)
                                    }
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(s.sessions.prefix(3)) { SessionRow(s: $0) }
                                if s.count > 3 {
                                    Text("+\(s.count - 3) more running")
                                        .font(.system(size: 11)).foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.top, 2)
                }
            } compactLeading: {
                BirdBadge(state: s)
            } compactTrailing: {
                if s.done {
                    Image(systemName: "checkmark").foregroundColor(olive)
                } else if let p = s.primary {
                    Text(timerInterval: p.start...p.freezeEnd, countsDown: false)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(olive).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 56)
                }
            } minimal: {
                BirdBadge(state: s, minimal: true)
            }
            // Green keyline on completion — animates with the working→done push so the
            // Island visibly flashes "complete" before it's torn down on `end`.
            .keylineTint(s.done ? olive : clay)
        }
    }
}

/// Bird icon with a small count badge when more than one prompt is running.
private struct BirdBadge: View {
    let state: WorkingAttributes.ContentState
    var minimal: Bool = false   // the minimal slot is a tiny circle → glyph only, no count badge
    var body: some View {
        // Fixed-size glyph + the count as an OVERLAY (doesn't expand layout bounds), so
        // the compact Dynamic Island slot sizes to the bird and never clips it. The old
        // ZStack + .offset badge widened the bounds past the slot → the bird got cut off.
        Image(systemName: state.done ? "checkmark.circle.fill" : "bird.fill")
            .font(.system(size: 16))
            .foregroundColor(state.done ? olive : clay)
            .contentTransition(.symbolEffect(.replace))   // animated glyph swap on done
            .overlay(alignment: .topTrailing) {
                if !minimal && !state.done && state.count > 1 {
                    Text(state.count > 9 ? "9+" : "\(state.count)")
                        .font(.system(size: 8, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 2).frame(minHeight: 11)
                        .background(Capsule().fill(olive))
                        .offset(x: 4, y: -3)
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
                Text(timerInterval: s.start...s.freezeEnd, countsDown: false)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(olive).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 58, alignment: .trailing)
                Text(workNote(s).map { "\(fmtTok(s.tokens)) tok · \($0)" }
                     ?? (s.tokens == 0 ? "starting…" : "\(fmtTok(s.tokens)) tok"))
                    .font(.system(size: 10)).foregroundColor(s.agents > 0 ? olive : .gray).lineLimit(1)
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
                    .contentTransition(.symbolEffect(.replace))   // animated bird→checkmark on done
                Text(state.done ? "Complete"
                     : (state.count > 1 ? "\(state.count) chats running" : (state.primary?.project ?? "Working")))
                    .font(.system(size: 15, weight: .semibold, design: .serif)).foregroundColor(.white).lineLimit(1)
                Spacer()
                if state.done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(olive)
                } else if let p = state.primary {
                    Text(timerInterval: p.start...p.freezeEnd, countsDown: false)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(olive).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 74, alignment: .trailing)
                }
            }
            if state.done {
                Text(state.doneDetail ?? "finished")
                    .font(.system(size: 13, design: .serif)).foregroundColor(.white.opacity(0.85))
            } else if state.count <= 1, let p = state.primary {
                Text("“\(p.prompt)”").font(.system(size: 13, design: .serif))
                    .foregroundColor(.white.opacity(0.85)).lineLimit(2)
                HStack(spacing: 7) {
                    Text(p.tokens == 0 ? "starting…" : "\(fmtTok(p.tokens)) tokens this turn")
                        .font(.system(size: 11)).foregroundColor(.gray)
                    if let note = workNote(p) {
                        Label(note, systemImage: "person.2.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(olive)
                    }
                }
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

/// "2 agents · 1 queued" proof-of-work caption, or nil when there's nothing extra to show.
private func workNote(_ l: WorkingAttributes.Line) -> String? {
    var parts: [String] = []
    if l.agents > 0 { parts.append("\(l.agents) agent\(l.agents == 1 ? "" : "s") working") }
    if l.queued > 0 { parts.append("\(l.queued) queued") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}
