import Testing
import Foundation
@testable import HermesNagCore

/// Every escalation transition, with an injected clock. No sleeps, no timers —
/// the engine is pure, so the whole ladder is exercised in microseconds.
@Suite struct ReminderEngineTests {

    let T0 = Date(timeIntervalSince1970: 1786539600)  // 2026-08-12T13:00:00Z
    let engine = ReminderEngine(nagProvider: { task, level in "L\(level.rawValue): \(task.title)" })

    private func task(_ id: String = "t1",
                      due: TimeInterval? = 0,
                      priority: Priority = .normal,
                      status: TaskStatus = .pending,
                      ignores: Int = 0,
                      snoozes: Int = 0,
                      snoozeUntil: TimeInterval? = nil,
                      noEscape: Bool = false,
                      serverLevel: Int = 0) -> Task {
        Task(id: id, title: "Task \(id)",
             dueAt: due.map { T0.addingTimeInterval($0) },
             priority: priority, status: status,
             snoozeUntil: snoozeUntil.map { T0.addingTimeInterval($0) },
             escalationLevel: serverLevel,
             ignoreCount: ignores, snoozeCount: snoozes, noEscape: noEscape)
    }

    private func presented(_ id: String, _ level: EscalationLevel,
                           shownAgo: TimeInterval = 0) -> UserState {
        UserState(presented: [id: PresentedNag(taskID: id, level: level,
                                               shownAt: T0.addingTimeInterval(-shownAgo))])
    }

    private func presents(_ actions: [ReminderAction]) -> [(String, EscalationLevel)] {
        actions.compactMap {
            if case .present(let id, let level, _) = $0 { return (id, level) }
            return nil
        }
    }

    // MARK: - The ladder

    @Test func nothingFiresBeforeDue() {
        let actions = engine.decide(tasks: [task(due: 600)], now: T0, state: UserState())
        #expect(presents(actions).isEmpty)
    }

    @Test func l1FiresExactlyAtDueTime() {
        let actions = engine.decide(tasks: [task(due: 0)], now: T0, state: UserState())
        #expect(presents(actions).map(\.0) == ["t1"])
        #expect(presents(actions).map(\.1) == [.playful])
    }

    @Test func l2AfterOneIgnore() {
        let actions = engine.decide(tasks: [task(ignores: 1)], now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .annoyed)
    }

    @Test func l2AfterTwoSnoozes() {
        let actions = engine.decide(tasks: [task(snoozes: 2)], now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .annoyed)
    }

    @Test func l2WhenThirtyMinutesOverdue() {
        let actions = engine.decide(tasks: [task(due: -1800)], now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .annoyed)
    }

    @Test func stillL1At29MinutesOverdue() {
        let actions = engine.decide(tasks: [task(due: -29 * 60)], now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .playful)
    }

    @Test func l3ForMustAfterTwoHoursOverdue() {
        let actions = engine.decide(tasks: [task(due: -7200, priority: .must)],
                                    now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .takeover)
    }

    @Test func l3ForMustAfterThreeIgnores() {
        let actions = engine.decide(tasks: [task(priority: .must, ignores: 3)],
                                    now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .takeover)
    }

    /// The most important guard in the app: a non-`must` task must NEVER
    /// take over the screen, no matter how long it's been ignored.
    @Test func normalPriorityNeverReachesTakeover() {
        let actions = engine.decide(
            tasks: [task(due: -48 * 3600, priority: .normal, ignores: 99)],
            now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .annoyed)
    }

    @Test func highPriorityNeverReachesTakeover() {
        let actions = engine.decide(
            tasks: [task(due: -48 * 3600, priority: .high, ignores: 99)],
            now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .annoyed)
    }

    @Test func noEscapeFlagForcesTakeoverImmediately() {
        let actions = engine.decide(tasks: [task(noEscape: true)], now: T0, state: UserState())
        #expect(presents(actions).first?.1 == .takeover)
    }

    // MARK: - Task lifecycle

    @Test func completedTasksNeverFire() {
        let actions = engine.decide(tasks: [task(due: -3600, status: .done)],
                                    now: T0, state: UserState())
        #expect(presents(actions).isEmpty)
    }

    @Test func droppedTasksNeverFire() {
        let actions = engine.decide(tasks: [task(due: -3600, status: .dropped)],
                                    now: T0, state: UserState())
        #expect(presents(actions).isEmpty)
    }

    @Test func snoozedTaskIsSilentUntilSnoozeExpires() {
        let t = task(due: -60, status: .snoozed, snoozeUntil: 600)
        #expect(presents(engine.decide(tasks: [t], now: T0, state: UserState())).isEmpty)

        // ...and fires once the snooze runs out.
        let later = T0.addingTimeInterval(601)
        #expect(!presents(engine.decide(tasks: [t], now: later, state: UserState())).isEmpty)
    }

    @Test func completingAShowingTaskDismissesItsPanel() {
        let actions = engine.decide(tasks: [task(due: -60, status: .done)],
                                    now: T0, state: presented("t1", .playful))
        #expect(actions.contains(.dismiss(taskID: "t1")))
    }

    // MARK: - No flicker / no duplicates

    @Test func doesNotRePresentAPanelAlreadyShowingAtTheSameLevel() {
        // Re-presenting every tick would make the panel flicker.
        let actions = engine.decide(tasks: [task()], now: T0,
                                    state: presented("t1", .playful))
        #expect(presents(actions).isEmpty)
    }

    @Test func upgradesAShowingPanelWhenLevelRises() {
        let actions = engine.decide(tasks: [task(ignores: 1)], now: T0,
                                    state: presented("t1", .playful))
        #expect(presents(actions).map(\.0) == ["t1"])
        #expect(presents(actions).map(\.1) == [.annoyed])
    }

    @Test func doesNotDowngradeAShowingPanel() {
        // Already at L2; a lower computed level shouldn't re-present.
        let actions = engine.decide(tasks: [task()], now: T0,
                                    state: presented("t1", .annoyed))
        #expect(presents(actions).isEmpty)
    }

    // MARK: - Auto-dismiss (L1 only)

    @Test func l1AutoDismissesAfterThirtySecondsAndCountsAsIgnored() {
        let actions = engine.decide(tasks: [task()], now: T0,
                                    state: presented("t1", .playful, shownAgo: 30))
        #expect(actions.contains(.reportIgnored(taskID: "t1", level: .playful)))
        #expect(actions.contains(.dismiss(taskID: "t1")))
    }

    @Test func l1DoesNotAutoDismissBeforeThirtySeconds() {
        let actions = engine.decide(tasks: [task()], now: T0,
                                    state: presented("t1", .playful, shownAgo: 29))
        #expect(!actions.contains(.reportIgnored(taskID: "t1", level: .playful)))
    }

    @Test func l2NeverAutoDismisses() {
        // Spec: L2 "does not auto-dismiss".
        let actions = engine.decide(tasks: [task(ignores: 1)], now: T0,
                                    state: presented("t1", .annoyed, shownAgo: 600))
        #expect(!actions.contains(.reportIgnored(taskID: "t1", level: .annoyed)))
        #expect(!actions.contains(.dismiss(taskID: "t1")))
    }

    @Test func timedOutL1RePresentsAtHigherLevelSameTick() {
        // Timed out AND now qualifies for L2 — it should escalate immediately
        // rather than waiting a full tick.
        let actions = engine.decide(tasks: [task(ignores: 1)], now: T0,
                                    state: presented("t1", .playful, shownAgo: 31))
        #expect(actions.contains(.reportIgnored(taskID: "t1", level: .playful)))
        #expect(presents(actions).first?.1 == .annoyed)
    }

    // MARK: - Dismissal cooldown

    @Test func recentlyDismissedTaskStaysQuiet() {
        var state = UserState()
        state.suppressedUntil = ["t1": T0.addingTimeInterval(300)]
        #expect(presents(engine.decide(tasks: [task()], now: T0, state: state)).isEmpty)
    }

    @Test func suppressionExpires() {
        var state = UserState()
        state.suppressedUntil = ["t1": T0.addingTimeInterval(-1)]
        #expect(!presents(engine.decide(tasks: [task()], now: T0, state: state)).isEmpty)
    }

    // MARK: - Safety valves

    @Test func nothingFiresWhileScreenIsLocked() {
        var state = UserState()
        state.screenLocked = true
        let actions = engine.decide(tasks: [task(priority: .must, ignores: 5)],
                                    now: T0, state: state)
        #expect(presents(actions).isEmpty, "queue for unlock, never fire")
    }

    @Test func lockedScreenDismissesAnythingAlreadyShowing() {
        var state = presented("t1", .annoyed)
        state.screenLocked = true
        #expect(engine.decide(tasks: [task()], now: T0, state: state)
                    .contains(.dismiss(taskID: "t1")))
    }

    @Test func takeoverDowngradesToL2WhilePresenting() {
        // Spec safety valve 1: never take over during screen share.
        var state = UserState()
        state.isPresenting = true
        let actions = engine.decide(tasks: [task(due: -7200, priority: .must)],
                                    now: T0, state: state)
        #expect(presents(actions).first?.1 == .annoyed, "downgrade, not silence")
    }

    @Test func killSwitchDowngradesTakeover() {
        var state = UserState()
        state.takeoverDisabled = true
        let actions = engine.decide(tasks: [task(due: -7200, priority: .must)],
                                    now: T0, state: state)
        #expect(presents(actions).first?.1 == .annoyed)
    }

    @Test func panicPauseSuppressesEverything() {
        var state = UserState()
        state.pausedUntil = T0.addingTimeInterval(3600)
        let actions = engine.decide(tasks: [task(priority: .must, ignores: 9)],
                                    now: T0, state: state)
        #expect(presents(actions).isEmpty)
    }

    @Test func panicPauseExpires() {
        var state = UserState()
        state.pausedUntil = T0.addingTimeInterval(-1)
        #expect(!presents(engine.decide(tasks: [task()], now: T0, state: state)).isEmpty)
    }

    // MARK: - Purity & determinism

    @Test func engineIsDeterministic() {
        let tasks = [task("a", ignores: 1), task("b", due: -7200, priority: .must), task("c", due: 600)]
        let first = engine.decide(tasks: tasks, now: T0, state: UserState())
        let second = engine.decide(tasks: tasks, now: T0, state: UserState())
        #expect(first == second, "same inputs must always give the same actions")
    }

    @Test func handlesMultipleTasksIndependently() {
        let tasks = [task("a"), task("b", ignores: 1), task("c", due: 600)]
        let levels = Dictionary(uniqueKeysWithValues: presents(
            engine.decide(tasks: tasks, now: T0, state: UserState())))

        #expect(levels["a"] == .playful)
        #expect(levels["b"] == .annoyed)
        #expect(levels["c"] == nil)  // not due yet
    }

    @Test func emptyTaskListProducesNoPanels() {
        #expect(presents(engine.decide(tasks: [], now: T0, state: UserState())).isEmpty)
    }

    @Test func ambientCountIsAlwaysReported() {
        let actions = engine.decide(tasks: [task(due: 300)], now: T0, state: UserState())
        let ambient = actions.compactMap { action -> Int? in
            if case .updateAmbient(let n) = action { return n }
            return nil
        }
        #expect(ambient == [1], "menu bar must always get a count")
    }

    // MARK: - Mascot

    @Test func mascotMoodTracksLevel() {
        #expect(MascotMood.forLevel(.ambient) == .idle)
        #expect(MascotMood.forLevel(.playful) == .cheerful)
        #expect(MascotMood.forLevel(.annoyed) == .sulking)
        #expect(MascotMood.forLevel(.takeover) == .glaring)
    }
}
