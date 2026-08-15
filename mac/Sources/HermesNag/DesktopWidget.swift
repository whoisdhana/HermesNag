import AppKit
import HermesNagCore
import SwiftUI

/// Always-visible desktop widget — the primary surface.
///
/// Deliberately the opposite of the nag panels: it sits *behind* your windows
/// at `.desktopIcon` level, never takes focus, never interrupts. You glance at
/// it. Dragging it around is the only interaction it demands.
/// Where the widget sits relative to your other windows — the user's call,
/// not ours. "Desktop" was the only behaviour originally, and it meant the
/// widget was invisible whenever a browser filled the screen.
enum WidgetLayer: String, CaseIterable {
    case desktop    // behind normal windows — glanceable on an empty desktop
    case normal     // an ordinary window — participates in the stack
    case floating   // above everything — always visible

    static let key = "widgetLayer"

    static var current: WidgetLayer {
        get {
            // Default .normal: click to bring forward, click elsewhere to send
            // back. Both extremes proved wrong as defaults — .desktop buried
            // it, .floating sat over videos.
            WidgetLayer(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .normal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    var windowLevel: NSWindow.Level {
        switch self {
        case .desktop: return .init(Int(NSWindow.Level.normal.rawValue) - 1)
        case .normal: return .normal
        case .floating: return .floating
        }
    }

    var label: String {
        switch self {
        case .desktop: return "Behind windows (desktop)"
        case .normal: return "Normal window"
        case .floating: return "Always on top"
        }
    }
}

/// A panel that can take keyboard focus **when clicked**, but never steals it.
///
/// `.nonactivatingPanel` alone leaves `canBecomeKey` false, so the "Add a
/// task…" field could never receive keystrokes — you could click it and type
/// into the void. Allowing key status fixes typing; `becomesKeyOnlyIfNeeded`
/// keeps the widget from grabbing focus just because it's on screen.
final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Click anywhere on the widget → bring it to the front. At `.normal`
    /// level, clicking any other window then naturally sends it back —
    /// exactly the "comes forward when I click it, gets out of the way when
    /// I click something else" behaviour the user asked for. (Floating was
    /// wrong: it sat over YouTube until closed.)
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            orderFrontRegardless()
        }
        super.sendEvent(event)
    }
}

@MainActor
final class DesktopWidgetController {
    private var window: NSPanel?
    private let store: AppStore

    private static let frameKey = "widgetFrame"
    private static let defaultSize = CGSize(width: 280, height: 340)

    init(store: AppStore) {
        self.store = store
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// True while the user wants the widget shown (independent of fullscreen
    /// suppression, so exiting fullscreen restores exactly what they had).
    private var userWantsVisible = true
    private var suppressedForFullScreen = false

    /// Hide while another app owns the screen; restore afterwards. A widget
    /// floating over full-screen YouTube is exactly the interruption this
    /// app promised never to be.
    func setFullScreenSuppression(_ suppress: Bool) {
        guard suppress != suppressedForFullScreen else { return }
        suppressedForFullScreen = suppress
        if suppress {
            window?.orderOut(nil)
        } else if userWantsVisible {
            window?.orderFrontRegardless()
        }
    }

    func show() {
        userWantsVisible = true
        if let window {
            if !suppressedForFullScreen { window.orderFront(nil) }
            return
        }

        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        // User-controlled layering (WidgetLayer). Historical note: never use
        // desktopIconWindow level — that sits behind the wallpaper, so the
        // panel existed in AppKit while the window server composited nothing.
        panel.level = WidgetLayer.current.windowLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true   // drag from anywhere
        panel.animationBehavior = .none
        // Only take focus when the user actually clicks into something that
        // needs it (the add-task field), never merely by being visible.
        panel.becomesKeyOnlyIfNeeded = true

        panel.contentView = NSHostingView(rootView: WidgetView(store: store))

        restoreFrame(panel)
        panel.orderFrontRegardless()

        // Remember where you put it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            guard let panel else { return }
            MainActor.assumeIsolated { Self.saveFrame(panel) }
        }

        window = panel
    }

    func hide() {
        userWantsVisible = false
        window?.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    private func restoreFrame(_ panel: NSPanel) {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            // Only honour a saved frame if it's *substantially* on a screen.
            // A mere `intersects` check accepted a one-pixel sliver, which is
            // how the widget ended up effectively invisible on a multi-display
            // setup after a monitor was rearranged.
            if Self.isUsablyVisible(frame) {
                panel.setFrame(frame, display: true)
                return
            }
        }
        placeDefault(panel)
    }

    /// At least this much of the widget must be on a real screen to count.
    private static func isUsablyVisible(_ frame: NSRect) -> Bool {
        let needed = frame.width * frame.height * 0.6
        return NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return !overlap.isNull && overlap.width * overlap.height >= needed
        }
    }

    /// Top-right of the primary display (the one with the menu bar, origin
    /// 0,0). Predictable beats clever: placing it on whichever screen the
    /// mouse happened to be on meant it appeared somewhere different each
    /// launch on a two-monitor setup.
    private func placeDefault(_ panel: NSPanel) {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let visible = primary?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: visible.maxX - Self.defaultSize.width - 24,
                                     y: visible.maxY - Self.defaultSize.height - 24))
    }

    /// Change layering immediately — no relaunch.
    func setLayer(_ layer: WidgetLayer) {
        WidgetLayer.current = layer
        window?.level = layer.windowLevel
        window?.orderFrontRegardless()
    }

    var layer: WidgetLayer { WidgetLayer.current }

    /// Bring the widget back to a sane spot — for when it's lost off-screen.
    func resetPosition() {
        guard let window else { return }
        UserDefaults.standard.removeObject(forKey: Self.frameKey)
        placeDefault(window)
        window.orderFrontRegardless()
        Self.saveFrame(window)
    }

    private static func saveFrame(_ panel: NSPanel) {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameKey)
    }
}

struct WidgetView: View {
    var theme: Theme { .shared }
    @Bindable var store: AppStore
    @State private var newTask = ""
    @State private var hovering = false
    @State private var now = Date()
    @FocusState private var addFieldFocused: Bool

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)
            taskList
            Divider().opacity(0.5)
            footer
        }
        .background {
            theme.backgroundView
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        }
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .preferredColorScheme(theme.scheme)
        .onHover { hovering = $0 }
        .onReceive(clock) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
                .help(store.statusLine)

            Text("Today")
                .font(.system(size: theme.fs(13), weight: .semibold))

            Spacer()

            if store.isRefreshing {
                ProgressView().controlSize(.mini).scaleEffect(0.6)
            }

            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: theme.fs(11), design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if forceTasks.isEmpty && pendingTasks.isEmpty
                    && completedToday.isEmpty && store.habits.isEmpty {
                    emptyState
                } else {
                    section("FORCE", tint: .red, tasks: forceTasks)
                    section("PENDING", tint: .secondary, tasks: pendingTasks)

                    if !activeHabits.isEmpty {
                        header("HABITS", tint: .secondary)
                        ForEach(activeHabits) { habit in
                            HabitRow(habit: habit) {
                                store.completeHabit(habit.id)
                            }
                        }
                    }

                    // Completed stays visible with a strikethrough — ticking a
                    // task off should feel like crossing it out, not like it
                    // evaporated.
                    if !completedToday.isEmpty {
                        header("COMPLETED", tint: .secondary)
                        ForEach(completedToday.prefix(6)) { task in
                            WidgetRow(task: task, now: now, done: true) {}
                        }
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func section(_ title: String, tint: Color, tasks: [Task]) -> some View {
        if !tasks.isEmpty {
            header(title, tint: tint)
            ForEach(tasks) { task in
                WidgetRow(task: task, now: now,
                          onSnooze: { minutes in
                              store.snoozeFromWidget(taskID: task.id, minutes: minutes)
                          }) {
                    store.completeFromWidget(taskID: task.id)
                }
            }
        }
    }

    /// Minutes from now until the next occurrence of `hour`:00 IST.
    static func minutesUntil(hour: Int, from now: Date) -> Int {
        let cal = Calendar.hermesNag
        var target = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now)!
        if target <= now { target = cal.date(byAdding: .day, value: 1, to: target)! }
        return max(1, Int(target.timeIntervalSince(now) / 60))
    }

    private func header(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: theme.fs(9), weight: .semibold))
            .foregroundStyle(tint.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// `must` tasks — the ones allowed to escalate to a takeover.
    private var forceTasks: [Task] {
        openTasks.filter { $0.priority == .must }
    }

    private var pendingTasks: [Task] {
        openTasks.filter { $0.priority != .must }
    }

    /// Done today (IST day, like every other day boundary in the app).
    private var completedToday: [Task] {
        store.tasks
            .filter { task in
                guard task.status == .done, let at = task.completedAt else { return false }
                return Calendar.hermesNag.isDate(at, inSameDayAs: now)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Due habits first, then by how soon they're coming.
    private var activeHabits: [Habit] {
        store.habits
            .filter { $0.enabled && $0.inActiveHours }
            .sorted {
                if $0.isDue != $1.isDue { return $0.isDue }
                return $0.secondsUntilDue < $1.secondsUntilDue
            }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            // Base this on whether requests actually succeed, not on the
            // tunnel's own state: an ssh process inherited from a previous
            // launch never transitions to .up, so the widget claimed
            // "Offline" while happily fetching tasks.
            Text(store.isConnected ? "All clear" : "Offline")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: theme.fs(12)))

                // Natural language: "call mum tomorrow 6pm #family" works.
                TextField("Add task… or habit: meditate daily", text: $newTask)
                    .textFieldStyle(.plain)
                    .font(.system(size: theme.fs(12)))
                    .focused($addFieldFocused)
                    .onSubmit(submit)

                // An explicit button: "type then press Return" isn't
                // discoverable, and the field looked broken without it.
                if !newTask.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: submit) {
                        Image(systemName: "return")
                            .font(.system(size: theme.fs(11), weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .help("Add task")
                }
            }
            .contentShape(Rectangle())
            // Clicking anywhere on the row focuses the field — a 12pt text
            // target is a fussy thing to hit.
            .onTapGesture { addFieldFocused = true }

            if let undo = store.undoCandidate {
                Button {
                    store.undoLastComplete()
                } label: {
                    Label("Undo \"\(undo.title.prefix(18))\"", systemImage: "arrow.uturn.backward")
                        .font(.system(size: theme.fs(11), weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(theme.accentColor)
            }

            if let stats = store.stats, let level = stats.level,
               let name = stats.levelName, let progress = stats.levelProgress {
                HStack(spacing: 6) {
                    Text("Lv\(level) \(name)")
                        .font(.system(size: theme.fs(9), weight: .bold))
                        .foregroundStyle(theme.accentColor)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(theme.accentColor.opacity(0.7))
                                .frame(width: max(3, geo.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                    if let today = stats.pointsToday, today > 0 {
                        Text("+\(today)")
                            .font(.system(size: theme.fs(9), weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                            .monospacedDigit()
                    }
                }
            }

            HStack(spacing: 10) {
                if let stats = store.stats, stats.streakDays > 0 {
                    Label("\(stats.streakDays)d", systemImage: "flame.fill")
                        .font(.system(size: theme.fs(10)))
                        .foregroundStyle(theme.accentColor)
                }
                if store.servingCached {
                    Label("cached", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: theme.fs(10)))
                        .foregroundStyle(.secondary)
                }
                if store.pendingCount > 0 {
                    Label("\(store.pendingCount)", systemImage: "arrow.up.circle")
                        .font(.system(size: theme.fs(10)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hovering {
                    Button { SettingsWindowController.shared.show() } label: {
                        Image(systemName: "gearshape").font(.system(size: theme.fs(10)))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Settings")

                    Button { _Concurrency.Task { await store.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: theme.fs(10)))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var openTasks: [Task] {
        store.tasks
            .filter(\.isOpen)
            .sorted {
                // Overdue and soonest first; undated sink to the bottom.
                ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
            }
    }

    private var indicatorColor: Color {
        switch store.indicator {
        case .green: return .green
        case .amber: return .orange
        case .red: return .red
        case .grey: return .gray
        }
    }

    private func submit() {
        let text = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newTask = ""
        store.addFromWidget(raw: text)
    }
}

/// A recurring habit with its countdown. Amber when due, so the widget alone
/// tells you what's outstanding without any popup.
struct HabitRow: View {
    var theme: Theme { .shared }
    let habit: Habit
    let onDone: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onDone) {
                Image(systemName: hovering ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: theme.fs(12)))
                    .foregroundStyle(hovering ? .green : (habit.isDue ? theme.accentColor : .secondary))
            }
            .buttonStyle(.borderless)
            .help(habit.isDue ? "Mark done" : "Next in \(habit.countdown)")

            Text(habit.name)
                .font(.system(size: theme.fs(11)))
                .foregroundStyle(habit.isDue ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if habit.streak > 0 {
                Text("\(habit.streak)")
                    .font(.system(size: theme.fs(9), design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(habit.countdown)
                .font(.system(size: theme.fs(10), design: .rounded))
                .foregroundStyle(habit.isDue ? theme.accentColor : Color.secondary.opacity(0.7))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(habit.isDue ? theme.accentColor.opacity(0.12)
                                  : (hovering ? Color.primary.opacity(0.06) : .clear))
        )
        .onHover { hovering = $0 }
    }

    /// A hint of what the habit is, at a glance.
    private var symbol: String {
        let name = habit.name.lowercased()
        if name.contains("water") { return "drop" }
        if name.contains("stand") || name.contains("stretch") { return "figure.stand" }
        if name.contains("eye") { return "eye" }
        if name.contains("wrap") { return "moon.stars" }
        return "repeat"
    }
}

struct WidgetRow: View {
    var theme: Theme { .shared }
    let task: Task
    let now: Date
    /// Section hint; the row also derives done from the task itself, so a
    /// completed task can never render as open no matter which section
    /// produced it (two freshly-completed rows once did exactly that).
    var done: Bool = false
    /// Right-click snooze ("yes, but later"). nil on completed rows.
    var onSnooze: ((Int) -> Void)? = nil
    let onComplete: () -> Void

    private var isDone: Bool { done || task.status == .done }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onComplete) {
                Image(systemName: isDone ? "checkmark.circle.fill"
                                        : (hovering ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: theme.fs(13)))
                    .foregroundStyle(isDone ? .green.opacity(0.6)
                                          : (hovering ? .green : priorityColor))
            }
            .buttonStyle(.borderless)
            .disabled(isDone)
            .help(isDone ? "Done" : "Mark done")

            Text(task.title)
                .font(.system(size: theme.fs(12)))
                .strikethrough(isDone, color: .secondary)
                .foregroundStyle(isDone ? Color.secondary.opacity(0.7) : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if task.recurrence != nil {
                Image(systemName: "repeat")
                    .font(.system(size: theme.fs(8)))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .help("Recurring — completing rolls to the next occurrence")
            }

            Spacer(minLength: 4)

            if let due = task.dueAt, !isDone {
                Text(shortDue(due))
                    .font(.system(size: theme.fs(10), design: .rounded))
                    .foregroundStyle(isOverdue ? .red : .secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
        .contextMenu {
            if let onSnooze, !isDone {
                Button("Snooze 1 hour") { onSnooze(60) }
                Button("Snooze until tonight (9pm)") {
                    onSnooze(WidgetView.minutesUntil(hour: 21, from: now))
                }
                Button("Snooze until tomorrow (9am)") {
                    onSnooze(WidgetView.minutesUntil(hour: 9, from: now))
                }
            }
        }
    }

    private var isOverdue: Bool { task.isOverdue(now: now) }

    private var priorityColor: Color {
        switch task.priority {
        case .must: return .red
        case .high: return .orange
        case .normal: return .secondary
        case .low: return .secondary.opacity(0.5)
        }
    }

    /// Compact: "18:00" today, "tmrw", "3d", or "2h late".
    private func shortDue(_ date: Date) -> String {
        let cal = Calendar.hermesNag
        if isOverdue {
            let mins = Int(now.timeIntervalSince(date) / 60)
            if mins < 60 { return "\(mins)m late" }
            if mins < 60 * 24 { return "\(mins / 60)h late" }
            return "\(mins / 1440)d late"
        }
        if cal.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(date, inSameDayAs: tomorrow) {
            return "tmrw"
        }
        let days = cal.dateComponents([.day], from: now, to: date).day ?? 0
        return "\(max(1, days))d"
    }
}
