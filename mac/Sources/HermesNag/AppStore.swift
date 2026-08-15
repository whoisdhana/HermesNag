import Foundation
import HermesNagCore
import Observation
import ServiceManagement

/// App state for the menu bar: owns the tunnel, the API client, and the cache.
///
/// M2 is read-only. Refresh is polled here; SSE (the primary push path)
/// arrives in M3 with the reminder engine.
@Observable
@MainActor
public final class AppStore {
    /// One store for the whole app.
    ///
    /// SwiftUI treats an `@State` initializer as a *template* it may discard
    /// and rebuild, so `AppStore()` written inline can produce an instance the
    /// UI never renders. Both the AppDelegate (launch) and the view must talk
    /// to the same object, hence a shared instance rather than two constructions.
    public static let shared = AppStore()

    public private(set) var tasks: [Task] = []
    public private(set) var summary: TodaySummary?
    public private(set) var health: Health?
    public private(set) var stats: Stats?
    public private(set) var lastError: String?
    public private(set) var lastRefresh: Date?
    public private(set) var isRefreshing = false
    /// True when showing cached data because the server is unreachable.
    public private(set) var servingCached = false

    public let tunnel: TunnelManager
    private let client: APIClient
    private let store: SnapshotStoring
    private var pollTask: _Concurrency.Task<Void, Never>?

    // --- M3: reminder engine ---------------------------------------------
    private let engine = ReminderEngine()
    private var userState = UserState()
    private var tickTask: _Concurrency.Task<Void, Never>?
    private var panels: NagPanelController?
    private let queueStore: ActionQueueStoring = FileActionQueueStore()
    /// Nag copy from the server's pre-generated pool, keyed by task ID.
    private var nagLines: [String: String] = [:]
    /// How long a user-dismissed task stays quiet.
    private let dismissCooldown: TimeInterval = 15 * 60

    // --- SSE (push) ---------------------------------------------------------
    private var events: EventStream?
    /// True while the SSE stream is delivering frames. Polling then relaxes
    /// to a slow safety net — the spec's "polling is the fallback".
    public private(set) var sseHealthy = false

    // --- Habits ------------------------------------------------------------
    public private(set) var habits: [Habit] = []
    private let presence = PresenceTracker()
    /// Habits already nudged this cycle, so one due habit doesn't fire every tick.
    private var habitNudgedAt: [String: Date] = [:]
    /// Safety net only — the server defers a fired habit a full interval, so
    /// this cadence should never be reached. 5 minutes here once turned a
    /// server-side anchor bug into a notification every 5 minutes.
    private let habitRenudge: TimeInterval = 15 * 60

    // --- M4: takeover ------------------------------------------------------
    private var takeovers: TakeoverWindowController?
    private var panicHotkey: GlobalHotkey?
    private var quickAddHotkey: GlobalHotkey?
    public private(set) var panicHotkeyRegistered = false
    /// Why the last takeover was held back, shown in the popover.
    public private(set) var lastTakeoverReason: TakeoverSuppression?

    private static let ledgerKey = "takeoverLedger"
    private static let nagsKey = "nagsEnabled"

    /// Nagging is **off by default** — the widget is the product.
    /// `defaults write com.dhana.hermesnag nagsEnabled -bool YES` turns the
    /// L1/L2/L3 ladder back on without a rebuild.
    public var nagsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.nagsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.nagsKey)
            if !newValue { dismissAllPanels() }
        }
    }

    /// The ledger outlives a relaunch on purpose: restarting the app must not
    /// hand you a fresh set of takeovers for the day.
    private func loadLedger() -> TakeoverLedger {
        guard let data = UserDefaults.standard.data(forKey: Self.ledgerKey),
              let ledger = try? JSON.decoder().decode(TakeoverLedger.self, from: data)
        else { return TakeoverLedger() }
        return ledger
    }

    private func persistLedger() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(userState.takeoverLedger) else { return }
        UserDefaults.standard.set(data, forKey: Self.ledgerKey)
    }

    // TunnelManager is @MainActor, so it can't be constructed in a default
    // argument (those evaluate outside the actor context). Passing nil and
    // building it here keeps the whole init on the main actor.
    public init(tunnel: TunnelManager? = nil,
                client: APIClient? = nil,
                store: SnapshotStoring = FileSnapshotStore()) {
        let tunnel = tunnel ?? TunnelManager()
        self.tunnel = tunnel
        self.client = client ?? APIClient(config: .init(baseURL: tunnel.baseURL))
        self.store = store

        // Show cached tasks immediately so the popover is never blank at launch.
        if let cached = store.load() {
            self.tasks = cached.tasks
            self.summary = TodayPlanner.summarize(tasks: cached.tasks, now: Date())
            self.servingCached = true
            self.lastRefresh = cached.capturedAt
        }
    }

    /// Idempotent: safe to call from both the AppDelegate (at launch) and the
    /// view's .task (when the popover first opens).
    public func start() {
        guard pollTask == nil else { return }
        tunnel.start()

        if panels == nil {
            panels = NagPanelController { [weak self] taskID, action in
                self?.handle(action, for: taskID)
            }
        }

        if takeovers == nil {
            takeovers = TakeoverWindowController { [weak self] taskID, result in
                self?.handleTakeover(result, for: taskID)
            }
        }

        userState.takeoverLedger = loadLedger()
        Notifications.requestAuthorization()

        // Idempotent server-side; makes the habits work out of the box.
        _Concurrency.Task {
            _ = try? await client.seedHabits()
            await refreshHabits()
        }

        if panicHotkey == nil {
            let hotkey = GlobalHotkey.panic { [weak self] in self?.panic() }
            panicHotkeyRegistered = hotkey.register()
            panicHotkey = hotkey
            DebugLog.write("panic hotkey registered: \(panicHotkeyRegistered)")
        }

        if quickAddHotkey == nil {
            let hotkey = GlobalHotkey.quickAdd { QuickAddController.shared.toggle() }
            let ok = hotkey.register()
            quickAddHotkey = hotkey
            DebugLog.write("quick-add hotkey registered: \(ok)")
        }

        // Push channel. Any task event → immediate refresh, so Hermes-created
        // tasks appear in seconds instead of on the next poll.
        if events == nil {
            let stream = EventStream(
                config: .init(baseURL: tunnel.baseURL),
                onEvent: { _ in
                    _Concurrency.Task { @MainActor in await AppStore.shared.refresh() }
                },
                onStateChange: { state in
                    _Concurrency.Task { @MainActor in
                        AppStore.shared.sseHealthy = (state == .connected)
                    }
                }
            )
            events = stream
            _Concurrency.Task { await stream.start() }
        }

        pollTask = _Concurrency.Task { [weak self] in
            // Give the tunnel a moment before the first request.
            try? await _Concurrency.Task.sleep(for: .seconds(1))
            while !_Concurrency.Task.isCancelled {
                await self?.refresh()
                // With a healthy push stream, polling is only a safety net.
                let interval: Double = (self?.sseHealthy ?? false) ? 120 : 30
                try? await _Concurrency.Task.sleep(for: .seconds(interval))
            }
        }

        // The engine has no timers inside it (that's what keeps it pure and
        // testable) — this driver is the only clock, ticking it every second.
        tickTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                self?.tick()
                self?.tickHabits()
                try? await _Concurrency.Task.sleep(for: .seconds(1))
            }
        }
    }

    public func stop() {
        pollTask?.cancel(); pollTask = nil
        tickTask?.cancel(); tickTask = nil
        if let events { _Concurrency.Task { await events.stop() } }
        panels?.dismissAll()
        tunnel.stop()
    }

    // MARK: - Engine driver

    /// One tick: ask the pure engine what should happen, then do it.
    func tick(now: Date = Date()) {
        // Refresh the safety valves from the real system before deciding.
        // Without this the guards are permanently stuck at their defaults —
        // the engine would happily take over the screen mid-Zoom call.
        let system = SystemState.current()
        userState.screenLocked = system.screenLocked
        userState.isPresenting = system.isPresenting
        userState.takeoverDisabled = system.takeoverDisabled

        // Step aside while another app is full-screen (YouTube, Keynote…) —
        // checked every tick so the widget vanishes within a second of
        // entering fullscreen and returns within a second of leaving.
        WidgetHost.shared.setFullScreenSuppression(SystemState.anotherAppIsFullScreen)

        let actions = engine.decide(tasks: tasks, now: now, state: userState)

        for action in actions {
            switch action {
            case .present(let taskID, let level, let fallbackLine):
                // Widget mode is the default: the desktop panel shows what's
                // due and nothing interrupts. The whole escalation ladder
                // still runs and stays tested — it just doesn't present.
                guard nagsEnabled else { continue }
                guard let task = tasks.first(where: { $0.id == taskID }) else { continue }
                let line = nagLines[taskID] ?? fallbackLine
                if level == .takeover {
                    takeovers?.present(task: task, nagLine: line)
                } else {
                    panels?.present(task: task, level: level, nagLine: line)
                }
                userState.presented[taskID] = PresentedNag(taskID: taskID, level: level,
                                                           shownAt: now)
                enqueue(.ack(taskID: taskID, level: level.rawValue, action: "shown"))

            case .dismiss(let taskID):
                panels?.dismiss(taskID: taskID)
                userState.presented[taskID] = nil

            case .reportIgnored(let taskID, let level):
                // Auto-dismissed with no interaction. ignore_count is what
                // drives escalation server-side, so push it promptly rather
                // than waiting up to 30s for the next poll.
                enqueue(.ack(taskID: taskID, level: level.rawValue, action: "ignored"))
                _Concurrency.Task { await flushQueue(refreshAfter: false) }

            case .takeoverFired(let taskID):
                // Recording here is what makes the rate limits real: the engine
                // is pure and can't remember what it fired last tick.
                userState.takeoverLedger.record(now)
                persistLedger()
                lastTakeoverReason = nil
                DebugLog.write("TAKEOVER fired for \(taskID.prefix(8)) — \(userState.takeoverLedger.countToday(now: now)) today")

            case .takeoverSuppressed(let taskID, let reason):
                // Spec: "Downgrade to L2 instead and log why."
                lastTakeoverReason = reason
                DebugLog.write("TAKEOVER suppressed for \(taskID.prefix(8)) — \(reason.rawValue)")

            case .updateAmbient:
                break  // the menu bar reads `summary` directly
            }
        }
    }

    // MARK: - Habits

    /// Check habits and nudge. Called from the tick loop.
    ///
    /// Habits escalate more gently than tasks: gentle notification first, then
    /// a small panel if ignored. They never reach takeover — a water reminder
    /// seizing the screen would be absurd.
    func tickHabits(now: Date = Date()) {
        presence.sample(now: now)

        for habit in habits where habit.isDue {
            // Already nudged recently? Leave it alone.
            if let last = habitNudgedAt[habit.id], now.timeIntervalSince(last) < habitRenudge {
                continue
            }
            habitNudgedAt[habit.id] = now

            let line = habit.nagLine ?? "\(habit.name) — time for a break."

            if habit.level >= 2 && habit.escalates {
                // Ignored once: escalate to a visible panel.
                let asTask = Task(id: habit.id, title: habit.name,
                                  dueAt: now, priority: .normal)
                panels?.present(task: asTask, level: .annoyed, nagLine: line)
            } else {
                Notifications.send(title: habit.name, body: line, identifier: habit.id)
            }

            _Concurrency.Task { [weak self] in
                try? await self?.client.habitFired(id: habit.id)
                await self?.refreshHabits()
            }
        }
    }

    public func completeHabit(_ habitID: String) {
        habitNudgedAt[habitID] = nil
        panels?.dismiss(taskID: habitID)
        Notifications.clear(identifier: habitID)

        // Standing up restarts the sitting clock straight away.
        if habits.first(where: { $0.id == habitID })?.requiresPresence == true {
            presence.recordBreak()
        }

        _Concurrency.Task {
            _ = try? await client.completeHabit(id: habitID)
            await refreshHabits()
        }
    }

    func refreshHabits() async {
        guard let fetched = try? await client.habits(presence: presence.snapshot) else { return }
        habits = fetched
    }

    /// A button on a nag panel.
    private func handle(_ action: NagAction, for taskID: String) {
        userState.presented[taskID] = nil

        // A simulated panel is for eyeballing the UI — it must not mutate
        // real data or enqueue anything.
        guard !taskID.hasPrefix(Self.simulatedIDPrefix) else { return }

        // Quiet for a while regardless of outcome, so acting on a panel never
        // immediately summons another one.
        userState.suppressedUntil[taskID] = Date().addingTimeInterval(dismissCooldown)

        switch action {
        case .done:
            applyLocally(taskID: taskID) { $0.completedLocally() }
            enqueue(.complete(taskID: taskID))
        case .snooze(let minutes):
            applyLocally(taskID: taskID) { $0.snoozedLocally(minutes: minutes) }
            enqueue(.snooze(taskID: taskID, minutes: minutes))
        case .notToday:
            applyLocally(taskID: taskID) { $0.droppedLocally() }
            enqueue(.drop(taskID: taskID))
        }

        _Concurrency.Task { await flushQueue() }
    }

    // MARK: - Widget actions

    /// Add a task from the widget's text field. Natural language is parsed
    /// server-side, so "call mum tomorrow 6pm #family" works.
    public func addFromWidget(raw: String) {
        _Concurrency.Task {
            do {
                // "habit: meditate daily" creates a habit; anything else a task.
                if raw.lowercased().hasPrefix("habit:") {
                    let rest = String(raw.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    _ = try await client.createHabit(raw: rest)
                    await refreshHabits()
                } else {
                    _ = try await client.create(raw: raw)
                }
                await refresh()
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // Undo: the last completion, offered for a few seconds. Accidental clicks
    // stop being destructive — especially on the phone's small targets.
    public struct UndoCandidate: Equatable {
        public let taskID: String
        public let title: String
        public let expires: Date
    }
    public private(set) var undoCandidate: UndoCandidate?

    /// Tick a task off from the widget. Same queued path as a nag panel, so it
    /// still works with the tunnel down.
    public func completeFromWidget(taskID: String) {
        let title = tasks.first(where: { $0.id == taskID })?.title ?? "task"
        applyLocally(taskID: taskID) { $0.completedLocally() }
        enqueue(.complete(taskID: taskID))
        undoCandidate = UndoCandidate(taskID: taskID, title: title,
                                      expires: Date().addingTimeInterval(6))
        _Concurrency.Task { [weak self] in
            await self?.flushQueue()
            try? await _Concurrency.Task.sleep(for: .seconds(6))
            if self?.undoCandidate?.taskID == taskID { self?.undoCandidate = nil }
        }
    }

    public func undoLastComplete() {
        guard let candidate = undoCandidate else { return }
        undoCandidate = nil
        _Concurrency.Task {
            _ = try? await client.reopen(taskID: candidate.taskID)
            await refresh()
        }
    }

    /// Snooze straight from a widget row: "yes, but later".
    public func snoozeFromWidget(taskID: String, minutes: Int) {
        applyLocally(taskID: taskID) { $0.snoozedLocally(minutes: minutes) }
        enqueue(.snooze(taskID: taskID, minutes: minutes))
        _Concurrency.Task { await flushQueue() }
    }

    /// Outcome of an L3 takeover.
    private func handleTakeover(_ result: TakeoverResult, for taskID: String) {
        switch result {
        case .done:
            handle(.done, for: taskID)
        case .escaped:
            // Escaping is not completing. The task stays open and keeps its
            // counts — but stay quiet a while so it isn't instantly re-shown,
            // which would make the escape hatch meaningless.
            userState.presented[taskID] = nil
            userState.suppressedUntil[taskID] = Date().addingTimeInterval(dismissCooldown)
            DebugLog.write("TAKEOVER escaped for \(taskID.prefix(8))")
        }
    }

    /// Optimistic local update so the UI reacts instantly, even offline.
    private func applyLocally(taskID: String, _ transform: (Task) -> Task) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[idx] = transform(tasks[idx])
        summary = TodayPlanner.summarize(tasks: tasks, now: Date())
    }

    // MARK: - Offline-tolerant action queue

    private func enqueue(_ action: PendingAction) {
        var queue = queueStore.load()
        queue.append(QueuedAction(action: action, queuedAt: Date()))
        queueStore.save(ActionQueuePolicy.coalesce(queue))
    }

    /// Drain the queue. Anything that fails stays queued for the next attempt —
    /// a completion must never be lost because ssh was reconnecting.
    /// True while a flush is in flight — see the guard below.
    private var isFlushing = false

    /// - Parameter refreshAfter: re-fetch once drained. False when called
    ///   from `refresh()` itself, to avoid recursing.
    func flushQueue(refreshAfter: Bool = true) async {
        // Reentrancy guard. The poll loop, panel actions and auto-dismiss all
        // call this; two overlapping flushes would both load the same queue
        // and send the same snooze twice — inflating snooze_count and driving
        // escalation the user never earned. One flush at a time; the queue is
        // durable, so anything a skipped caller wanted goes out next round.
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        var queue = queueStore.load()
        guard !queue.isEmpty else { return }

        var remaining: [QueuedAction] = []
        let now = Date()

        for var item in ActionQueuePolicy.coalesce(queue) {
            if ActionQueuePolicy.shouldDrop(item, now: now) { continue }
            do {
                switch item.action {
                case .complete(let id):
                    let result = try await client.complete(taskID: id)
                    lastCompletion = result
                case .snooze(let id, let minutes):
                    _ = try await client.snooze(taskID: id, minutes: minutes)
                case .drop(let id):
                    _ = try await client.drop(taskID: id)
                case .ack(let id, let level, let action):
                    try await client.ack(taskID: id, level: level, action: action)
                }
            } catch let error as APIClient.ClientError {
                // Permanent outcomes — retrying can never change them, and a
                // stuck entry blocks everything behind it and pins the UI to
                // "Offline". Observed live: a completion that had *succeeded*
                // retried 4,514 times because the server answers 409 "already
                // done" on the second attempt.
                //   409 = already in the desired state -> treat as success
                //   404 = task no longer exists
                //   400 = malformed, will never be accepted
                if case .http(let code, _) = error, code == 409 || code == 404 || code == 400 {
                    continue
                }
                item.attempts += 1
                remaining.append(item)
            } catch {
                item.attempts += 1
                remaining.append(item)
            }
        }

        queue = remaining
        queueStore.save(queue)
        pendingCount = queue.count

        if remaining.isEmpty && refreshAfter { await refresh() }
    }

    public private(set) var pendingCount = 0
    public private(set) var lastCompletion: CompletionResult?

    // MARK: - Debug simulator

    /// Fire any level on demand, so escalation can be tested deliberately
    /// instead of waiting for real tasks to go overdue (spec: Debug/SimulatorMenu).
    /// Simulated tasks carry this prefix so their button presses never turn
    /// into real server mutations. Without it, clicking Done on a simulated
    /// panel queues a completion for a task ID the server has never seen,
    /// which then retries forever and blocks the rest of the queue.
    static let simulatedIDPrefix = "debug-"

    public func simulate(level: EscalationLevel) {
        let sample = Task(id: "\(Self.simulatedIDPrefix)\(level.rawValue)",
                          title: "Simulated L\(level.rawValue) reminder",
                          dueAt: Date().addingTimeInterval(-600),
                          priority: level == .takeover ? .must : .normal)

        // L3 gets the full-screen treatment, and honours the valves even when
        // simulated — otherwise the debug menu could take over your screen
        // mid-call, which is precisely what the valves exist to prevent.
        if level == .takeover {
            let system = SystemState.current()
            if let reason = engine.policy.suppression(
                now: Date(), ledger: userState.takeoverLedger,
                isPresenting: system.isPresenting,
                killSwitch: system.takeoverDisabled,
                screenLocked: system.screenLocked
            ) {
                lastTakeoverReason = reason
                DebugLog.write("SIMULATED takeover suppressed — \(reason.rawValue)")
                panels?.present(task: sample, level: .annoyed,
                                nagLine: "Takeover held back: \(reason.userMessage)")
                return
            }
            takeovers?.present(task: sample,
                               nagLine: "Simulated takeover. This is what L3 looks like.")
            return
        }

        let line = nagLines[sample.id]
            ?? "Simulated L\(level.rawValue) nag for \(sample.title)."

        panels?.present(task: sample, level: level, nagLine: line)
        // Not recorded in userState.presented: a simulated panel shouldn't
        // count as ignored or drive real escalation.
    }

    public func dismissAllPanels() {
        panels?.dismissAll()
        takeovers?.dismiss()
        userState.presented.removeAll()
    }

    /// Panic exit (⌃⌥⌘Esc): kill every window and go quiet for 60 minutes.
    ///
    /// Logged to the server as a `panic` event because the spec asks for it:
    /// "I want to see how often I chicken out."
    public func panic() {
        dismissAllPanels()
        userState.pausedUntil = Date().addingTimeInterval(60 * 60)
        DebugLog.write("PANIC — paused until \(userState.pausedUntil.map(String.init(describing:)) ?? "?")")

        // Attributed to whatever was on screen, or the most urgent open task.
        let subject = userState.presented.keys.first
            ?? tasks.first(where: { $0.isOpen && $0.isOverdue(now: Date()) })?.id
        if let subject {
            enqueue(.ack(taskID: subject, level: 0, action: "ignored"))
            _Concurrency.Task { await flushQueue(refreshAfter: false) }
        }
    }

    public var isPaused: Bool { userState.isPaused(now: Date()) }

    // MARK: - Login item (M7)

    /// Survives reboot — the app was dying with the session before this.
    /// SMAppService is unreliable from a build directory, so `make install`
    /// puts the bundle in /Applications first.
    public var startsAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                DebugLog.write("login item \(newValue ? "registered" : "unregistered")")
            } catch {
                lastError = "Login item: \(error.localizedDescription)"
                DebugLog.write("login item FAILED: \(error.localizedDescription)")
            }
        }
    }

    /// "2 left today · 31m cooldown" — so the L3 budget is inspectable rather
    /// than something you infer from takeovers mysteriously not happening.
    public var takeoverBudget: String {
        let now = Date()
        let left = engine.policy.remainingToday(now: now, ledger: userState.takeoverLedger)
        let cool = engine.policy.cooldownRemaining(now: now, ledger: userState.takeoverLedger)
        if cool > 0 {
            return "\(left) left today · \(Int(cool / 60))m cooldown"
        }
        return "\(left) left today"
    }

    public var valveStatus: String {
        let s = SystemState.current()
        var active: [String] = []
        if s.screenLocked { active.append("locked") }
        if s.isPresenting { active.append("presenting") }
        if s.takeoverDisabled { active.append("kill switch") }
        return active.isEmpty ? "no valves active" : active.joined(separator: ", ")
    }

    public func resume() {
        userState.pausedUntil = nil
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let fetched = try await client.tasks()
            tasks = fetched
            summary = TodayPlanner.summarize(tasks: fetched, now: Date())
            lastRefresh = Date()
            lastError = nil
            servingCached = false
            store.save(Snapshot(tasks: fetched, capturedAt: Date()))

            health = try? await client.health()
            let previousLevel = stats?.level
            stats = try? await client.stats()
            // Level-up celebration — game-y flavour, the user's choice.
            if let old = previousLevel, let new = stats?.level, new > old,
               let name = stats?.levelName {
                Notifications.send(title: "Level up! \(name)",
                                   body: "You reached level \(new) — \(stats?.pointsTotal ?? 0) points.",
                                   identifier: "levelup")
                Theme.shared.playAlert()
            }

            // Pull nag copy from the server's pre-generated pool. Hermes takes
            // 14-17s per call, so this can never be on the presentation path —
            // panels read whatever was cached here, or a static fallback.
            if let due = try? await client.due() {
                for item in due.due { nagLines[item.id] = item.nagLine }
            }

            // Drain anything queued while we were offline. Without this, acks
            // from auto-dismissed panels pile up forever and the server never
            // learns the task was ignored — so escalation stalls at L1.
            await flushQueue(refreshAfter: false)
            await refreshHabits()
        } catch {
            // Keep showing the cache rather than blanking the list —
            // offline degrades, it doesn't fail.
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            servingCached = !tasks.isEmpty
        }
    }

    /// Menu bar glyph. Reflects tunnel state first (you can't trust task data
    /// you couldn't fetch), then whether anything is overdue.
    public var menuBarSymbol: String {
        if case .down = tunnel.state { return "bell.slash" }
        if let s = summary, s.needsAttention { return "bell.badge.fill" }
        return "bell"
    }

    /// True when the last refresh actually reached the server.
    ///
    /// More honest than `tunnel.state.isUp`: the tunnel only reports `.up`
    /// after *this* process spawned it, so an inherited ssh made the UI say
    /// "Offline" while data was flowing normally.
    public var isConnected: Bool {
        lastError == nil && lastRefresh != nil && !servingCached
    }

    public var indicator: Indicator {
        if isConnected { return .green }
        return tunnel.state.indicator
    }

    public var statusLine: String {
        if let lastError, !tunnel.state.isUp {
            return lastError
        }
        return tunnel.state.describedForUser
    }
}
