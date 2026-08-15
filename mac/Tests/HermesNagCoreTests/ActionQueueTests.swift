import Testing
import Foundation
@testable import HermesNagCore

/// Offline queue policy. Losing a completion because ssh was reconnecting
/// would be the worst possible bug in this app, so these are load-bearing.
@Suite struct ActionQueueTests {

    let T0 = Date(timeIntervalSince1970: 1786539600)

    private func q(_ action: PendingAction, ago: TimeInterval = 0,
                   attempts: Int = 0) -> QueuedAction {
        QueuedAction(action: action, queuedAt: T0.addingTimeInterval(-ago), attempts: attempts)
    }

    // MARK: - Coalescing

    @Test func snoozeSupersededByCompletionIsDropped() {
        // Re-sending a snooze after a completion would resurrect a finished task.
        let queue = [q(.snooze(taskID: "a", minutes: 10)), q(.complete(taskID: "a"))]
        let out = ActionQueuePolicy.coalesce(queue)

        #expect(out.count == 1)
        #expect(out.first?.action == .complete(taskID: "a"))
    }

    @Test func duplicateCompletionsCollapseToOne() {
        let out = ActionQueuePolicy.coalesce([q(.complete(taskID: "a")), q(.complete(taskID: "a"))])
        #expect(out.count == 1)
    }

    @Test func actionsForDifferentTasksAreIndependent() {
        let out = ActionQueuePolicy.coalesce([q(.complete(taskID: "a")), q(.complete(taskID: "b"))])
        #expect(out.count == 2)
    }

    @Test func acksSurviveCoalescing() {
        // Acks are telemetry for a different task; they shouldn't be swept up.
        let out = ActionQueuePolicy.coalesce([
            q(.ack(taskID: "a", level: 1, action: "shown")),
            q(.complete(taskID: "b")),
        ])
        #expect(out.count == 2)
    }

    @Test func snoozeSurvivesWhenTaskIsNotCompleted() {
        let out = ActionQueuePolicy.coalesce([q(.snooze(taskID: "a", minutes: 10))])
        #expect(out.count == 1)
    }

    // MARK: - Retry / expiry

    @Test func criticalActionsSurviveOrdinaryFailures() {
        // A completion is the user's intent — a handful of failures (dropped
        // tunnel, server restart) must not discard it.
        let item = q(.complete(taskID: "a"), attempts: 10)
        #expect(!ActionQueuePolicy.shouldDrop(item, now: T0))
    }

    /// Corrects an earlier assumption. This test used to assert that critical
    /// actions retry *forever*, which sounded safe but produced a completion
    /// stuck at 4,514 attempts in real use: the server answered 409 "already
    /// done" every time, and the wedged queue pinned the UI to "Offline".
    /// Unbounded retry is a spin, not a guarantee.
    @Test func criticalActionsStillGiveUpEventually() {
        let item = q(.complete(taskID: "a"), attempts: ActionQueuePolicy.criticalMaxAttempts)
        #expect(ActionQueuePolicy.shouldDrop(item, now: T0))
    }

    @Test func acksAreDroppedAfterMaxAttempts() {
        let item = q(.ack(taskID: "a", level: 1, action: "shown"), attempts: 5)
        #expect(ActionQueuePolicy.shouldDrop(item, now: T0))
    }

    @Test func staleActionsAreDropped() {
        let item = q(.complete(taskID: "a"), ago: 8 * 24 * 3600)
        #expect(ActionQueuePolicy.shouldDrop(item, now: T0))
    }

    @Test func recentActionsAreKept() {
        #expect(!ActionQueuePolicy.shouldDrop(q(.complete(taskID: "a"), ago: 3600), now: T0))
    }

    @Test func completionIsCriticalAckIsNot() {
        #expect(PendingAction.complete(taskID: "a").isCritical)
        #expect(PendingAction.drop(taskID: "a").isCritical)
        #expect(!PendingAction.ack(taskID: "a", level: 1, action: "shown").isCritical)
    }

    // MARK: - Persistence

    @Test func queueRoundTripsThroughStore() {
        let store = MemoryActionQueueStore()
        store.save([q(.complete(taskID: "a"))])
        #expect(store.load().first?.action == .complete(taskID: "a"))
    }

    @Test func queueEncodesAndDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([q(.snooze(taskID: "x", minutes: 10))])
        let decoded = try JSON.decoder().decode([QueuedAction].self, from: data)
        #expect(decoded.first?.action == .snooze(taskID: "x", minutes: 10))
    }

    // MARK: - Optimistic local mutations

    @Test func completingLocallyMarksDone() {
        let t = Task(id: "a", title: "x").completedLocally(now: T0)
        #expect(t.status == .done)
        #expect(t.completedAt == T0)
        #expect(!t.isOpen)
    }

    @Test func snoozingLocallyIncrementsCountAndSetsDeadline() {
        let t = Task(id: "a", title: "x").snoozedLocally(minutes: 10, now: T0)
        #expect(t.status == .snoozed)
        #expect(t.snoozeCount == 1)
        #expect(t.snoozeUntil == T0.addingTimeInterval(600))
    }

    @Test func droppingLocallySetsStatusNotDeletion() {
        // 'dropped' is a status — the row must survive.
        let t = Task(id: "a", title: "x").droppedLocally()
        #expect(t.status == .dropped)
        #expect(t.id == "a")
    }

    @Test func localMutationsPreserveOtherFields() {
        let original = Task(id: "a", title: "keep me", notes: "note",
                            priority: .must, tags: ["home"], noEscape: true)
        let done = original.completedLocally(now: T0)

        #expect(done.title == "keep me")
        #expect(done.notes == "note")
        #expect(done.priority == .must)
        #expect(done.tags == ["home"])
        #expect(done.noEscape)
    }

    /// A stuck action must not block the rest of the queue.
    ///
    /// Observed live: clicking Done on a *simulated* debug panel queued a
    /// completion for task "debug-3", which the server 404s. It retried
    /// forever (8 attempts and counting) and the queue grew instead of
    /// draining. Non-critical actions must eventually age out.
    @Test func nonCriticalActionsDoNotRetryForever() {
        let stuck = q(.ack(taskID: "debug-3", level: 1, action: "shown"), attempts: 5)
        #expect(ActionQueuePolicy.shouldDrop(stuck, now: T0))
    }

    @Test func staleCriticalActionsEventuallyAgeOut() {
        // Critical actions ignore the attempt cap, so age is the only backstop
        // that stops a permanently-rejected completion living forever.
        let ancient = q(.complete(taskID: "debug-3"), ago: 8 * 24 * 3600, attempts: 99)
        #expect(ActionQueuePolicy.shouldDrop(ancient, now: T0))
    }

    @Test func twoSnoozesReachL2Threshold() {
        // Ties the local mutation back to the ladder: snoozing twice is one of
        // the documented ways to reach L2.
        let t = Task(id: "a", title: "x", dueAt: T0)
            .snoozedLocally(minutes: 1, now: T0)
            .snoozedLocally(minutes: 1, now: T0)
        #expect(t.snoozeCount == 2)

        let awake = Task(id: "a", title: "x", dueAt: T0, snoozeCount: 2)
        #expect(Escalation.level(for: awake, now: T0) == .annoyed)
    }
}
