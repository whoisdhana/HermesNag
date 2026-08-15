import Foundation

/// THE state machine.
///
/// `decide(tasks:now:state:) -> [Action]` is a **pure function**. There are no
/// timers, no clocks, and no I/O inside it — a driver calls it on a tick and
/// executes whatever it returns. That's what makes every escalation path
/// testable in microseconds instead of via sleeps (spec Rule 3).
///
/// The engine decides *what should happen*. It never presents anything itself.

public enum ReminderAction: Equatable, Sendable {
    /// Show or upgrade a nag for this task at this level.
    case present(taskID: String, level: EscalationLevel, nagLine: String)
    /// Take down a panel that should no longer be on screen.
    case dismiss(taskID: String)
    /// The panel timed out with no interaction — tell the server.
    case reportIgnored(taskID: String, level: EscalationLevel)
    /// Update the menu bar glyph/badge.
    case updateAmbient(count: Int)
    /// A takeover was refused and downgraded to L2. Emitted so the reason is
    /// visible — a silent downgrade is indistinguishable from a bug.
    case takeoverSuppressed(taskID: String, reason: TakeoverSuppression)
    /// A takeover is being shown. The driver records it in the ledger, which
    /// is what makes the rate limits real.
    case takeoverFired(taskID: String)
}

/// Everything the engine needs to know about the world, passed in explicitly.
public struct UserState: Sendable {
    /// Currently visible panels: taskID -> what we're showing.
    public var presented: [String: PresentedNag]
    /// Panels the user dismissed; suppressed until this instant.
    public var suppressedUntil: [String: Date]
    /// Screen is locked — the spec says queue, never fire.
    public var screenLocked: Bool
    /// Screen sharing / presenting — downgrade rather than take over.
    public var isPresenting: Bool
    /// Panic hotkey pressed; everything paused until this instant.
    public var pausedUntil: Date?
    /// L3 kill switch (`defaults write com.dhana.hermesnag disableTakeover -bool YES`).
    public var takeoverDisabled: Bool
    /// Takeovers already shown, for rate limiting.
    public var takeoverLedger: TakeoverLedger

    public init(presented: [String: PresentedNag] = [:],
                suppressedUntil: [String: Date] = [:],
                screenLocked: Bool = false,
                isPresenting: Bool = false,
                pausedUntil: Date? = nil,
                takeoverDisabled: Bool = false,
                takeoverLedger: TakeoverLedger = TakeoverLedger()) {
        self.takeoverLedger = takeoverLedger
        self.presented = presented
        self.suppressedUntil = suppressedUntil
        self.screenLocked = screenLocked
        self.isPresenting = isPresenting
        self.pausedUntil = pausedUntil
        self.takeoverDisabled = takeoverDisabled
    }

    public func isPaused(now: Date) -> Bool {
        guard let pausedUntil else { return false }
        return now < pausedUntil
    }
}

public struct PresentedNag: Equatable, Sendable {
    public let taskID: String
    public let level: EscalationLevel
    public let shownAt: Date

    public init(taskID: String, level: EscalationLevel, shownAt: Date) {
        self.taskID = taskID
        self.level = level
        self.shownAt = shownAt
    }

    /// L1 auto-dismisses after 30s and counts as ignored. L2 and above never
    /// time out — the spec says they don't auto-dismiss.
    public func hasTimedOut(now: Date) -> Bool {
        guard level == .playful else { return false }
        return now.timeIntervalSince(shownAt) >= Escalation.playfulAutoDismiss
    }
}

public struct ReminderEngine: Sendable {
    /// Nag copy for a task+level. Injected so the engine stays pure and the
    /// tests are deterministic; the real one reads the pre-generated pool.
    public let nagProvider: @Sendable (Task, EscalationLevel) -> String

    public let policy: TakeoverPolicy

    public init(nagProvider: @escaping @Sendable (Task, EscalationLevel) -> String = { task, _ in
        "\(task.title) is due."
    },
                policy: TakeoverPolicy = TakeoverPolicy()) {
        self.nagProvider = nagProvider
        self.policy = policy
    }

    /// Pure. Same inputs always produce the same actions.
    public func decide(tasks: [Task], now: Date, state: UserState) -> [ReminderAction] {
        var actions: [ReminderAction] = []

        // --- Global suppression ------------------------------------------------
        // Locked screen: the spec says queue for unlock, never fire. Panic
        // pause: same. In both cases take down anything already up, so the
        // user doesn't unlock to a pile of stale panels.
        if state.screenLocked || state.isPaused(now: now) {
            for taskID in state.presented.keys.sorted() {
                actions.append(.dismiss(taskID: taskID))
            }
            actions.append(.updateAmbient(count: ambientCount(tasks: tasks, now: now)))
            return actions
        }

        // --- Timed-out L1 panels ----------------------------------------------
        // Handled before presenting, so a task that times out can immediately
        // re-present at the higher level on this same tick.
        for (taskID, nag) in state.presented.sorted(by: { $0.key < $1.key })
        where nag.hasTimedOut(now: now) {
            actions.append(.reportIgnored(taskID: taskID, level: nag.level))
            actions.append(.dismiss(taskID: taskID))
        }

        // --- Per-task decisions ------------------------------------------------
        for task in tasks.sorted(by: { $0.id < $1.id }) {
            let (desired, suppression) = desiredLevel(for: task, now: now, state: state)
            let current = state.presented[task.id]
            let timedOut = current?.hasTimedOut(now: now) ?? false

            // Closed, snoozed, or no longer due — take the panel down.
            guard desired > .ambient else {
                if current != nil, !timedOut {
                    actions.append(.dismiss(taskID: task.id))
                }
                continue
            }

            // Recently dismissed by the user: stay quiet until the cooldown
            // expires, otherwise clicking "Done" would just summon it again.
            if let until = state.suppressedUntil[task.id], now < until {
                continue
            }

            if let current, !timedOut {
                // Already showing. Only act if it needs to escalate — never
                // re-present the same level, or the panel would flicker on
                // every tick.
                if desired > current.level {
                    appendPresent(&actions, task: task, level: desired, suppression: suppression)
                }
                continue
            }

            appendPresent(&actions, task: task, level: desired, suppression: suppression)
        }

        actions.append(.updateAmbient(count: ambientCount(tasks: tasks, now: now)))
        return actions
    }

    /// Emits the present, plus the takeover bookkeeping that goes with it.
    private func appendPresent(_ actions: inout [ReminderAction],
                               task: Task,
                               level: EscalationLevel,
                               suppression: TakeoverSuppression?) {
        if let suppression {
            actions.append(.takeoverSuppressed(taskID: task.id, reason: suppression))
        }
        actions.append(.present(taskID: task.id, level: level,
                                nagLine: nagProvider(task, level)))
        if level == .takeover {
            actions.append(.takeoverFired(taskID: task.id))
        }
    }

    /// Level after applying safety valves, plus the reason if L3 was refused.
    ///
    /// Every downgrade carries a named reason. The spec asks for "downgrade to
    /// L2 instead and log why", and an unexplained downgrade looks exactly like
    /// a broken escalation ladder.
    func desiredLevel(for task: Task, now: Date,
                      state: UserState) -> (level: EscalationLevel, reason: TakeoverSuppression?) {
        let level = Escalation.level(for: task, now: now)
        guard level == .takeover else { return (level, nil) }

        if let reason = policy.suppression(now: now,
                                           ledger: state.takeoverLedger,
                                           isPresenting: state.isPresenting,
                                           killSwitch: state.takeoverDisabled,
                                           screenLocked: state.screenLocked) {
            return (.annoyed, reason)
        }
        return (.takeover, nil)
    }

    private func ambientCount(tasks: [Task], now: Date) -> Int {
        tasks.filter { Escalation.isAmbient(task: $0, now: now) || Escalation.level(for: $0, now: now) > .ambient }
             .count
    }
}
