import HermesNagCore
import SwiftUI

/// The popover: today's tasks, tunnel state, and a manual refresh.
/// Read-only in M2 — no Done/Snooze buttons until M3 wires the actions.
struct MenuPopover: View {
    @Bindable var store: AppStore
    private let now = Date()

    var body: some View {
        // Slim by design: the task list lives in ONE place (the widget) with
        // ONE vocabulary. This is just status + doors: two surfaces showing
        // the same tasks under different section names read as two apps.
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            quickStatus
            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("HermesNag").font(.headline)
                Text(store.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                _Concurrency.Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing
                               ? .linear(duration: 1).repeatForever(autoreverses: false)
                               : .default,
                               value: store.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(12)
    }

    private var quickStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            let open = store.tasks.filter(\.isOpen)
            let due = store.habits.filter { $0.enabled && $0.inActiveHours && $0.isDue }

            HStack(spacing: 14) {
                Label("\(open.count) open", systemImage: "circle")
                if !due.isEmpty {
                    Label("\(due.count) habit\(due.count == 1 ? "" : "s") due",
                          systemImage: "repeat")
                        .foregroundStyle(.orange)
                }
                if let stats = store.stats, stats.streakDays > 0 {
                    Label("\(stats.streakDays)d", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button("Show widget") {
                    WidgetHost.shared.show()
                }
                Button("Quick add  ⌃⌥Space") { QuickAddController.shared.open() }
                Button("Settings…") { SettingsWindowController.shared.show() }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func taskList(_ summary: TodaySummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(summary.buckets, id: \.bucket) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.bucket.title.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(entry.tasks) { task in
                            TaskRow(task: task, now: now,
                                    isOverdue: entry.bucket == .overdue)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 340)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(store.tunnel.state.isUp ? "Nothing due. Enjoy it." : "No cached tasks")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            if store.servingCached {
                Label("Cached", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Showing the last known state — the server is unreachable")
            } else if let stats = store.stats, stats.streakDays > 0 {
                Label("\(stats.streakDays)d streak", systemImage: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if store.pendingCount > 0 {
                Label("\(store.pendingCount) queued", systemImage: "arrow.up.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Actions waiting to sync to the server")
            }

            Spacer()

            if case .down = store.tunnel.state {
                Button("Retry") { store.tunnel.retryNow() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }

            // Debug simulator — fire any level without waiting for a real
            // task to go overdue.
            Menu {
                Button(WidgetHost.shared.isVisible ? "Hide widget" : "Show widget") {
                    WidgetHost.shared.toggle()
                }
                Button("Reset widget position") {
                    WidgetHost.shared.resetPosition()
                }
                Button("Settings…") { SettingsWindowController.shared.show() }
                Divider()
                Button("Fire L1 — playful") { store.simulate(level: .playful) }
                Button("Fire L2 — annoyed") { store.simulate(level: .annoyed) }
                Button("Fire L3 — takeover") { store.simulate(level: .takeover) }
                Divider()
                Text(store.nagsEnabled ? "Nagging: ON" : "Nagging: off (widget only)")
                Text("L3 budget: \(store.takeoverBudget)")
                Text("Valves: \(store.valveStatus)")
                Text(store.panicHotkeyRegistered
                     ? "Panic hotkey: ⌃⌥⌘Esc"
                     : "Panic hotkey: NOT registered")
                if let reason = store.lastTakeoverReason {
                    Text("Last held back: \(reason.userMessage)")
                }
                Divider()
                Button("Dismiss all panels") { store.dismissAllPanels() }
                if store.isPaused {
                    Button("Resume (paused)") { store.resume() }
                } else {
                    Button("Panic — pause 60m") { store.panic() }
                }
                Divider()
                Button("Sync now") {
                    _Concurrency.Task { await store.flushQueue() }
                }
            } label: {
                Image(systemName: "ladybug")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Debug: fire any escalation level")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var indicatorColor: Color {
        switch store.indicator {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        case .grey: return .gray
        }
    }
}

struct TaskRow: View {
    let task: Task
    let now: Date
    var isOverdue: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(priorityColor)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.callout)
                    .lineLimit(2)

                if let due = task.dueAt {
                    Text(TodayPlanner.relativeLabel(for: due, now: now))
                        .font(.caption2)
                        .foregroundStyle(isOverdue ? .red : .secondary)
                }
            }

            Spacer(minLength: 4)

            if task.priority == .must {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help("must — can escalate to takeover")
            }
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .must: return .red
        case .high: return .orange
        case .normal: return .blue
        case .low: return .gray
        }
    }
}
