import Testing
import Foundation
@testable import HermesNagCore

/// Grouping/ordering for the popover. `now` is injected, so no sleeping.
@Suite struct TodayPlannerTests {
    init() {
        // These tests assert IST-vs-UTC boundary behaviour specifically.
        UserDefaults.standard.set("Asia/Kolkata", forKey: "displayTimeZone")
    }

    /// 2026-08-12 12:00 UTC == 17:30 IST — deliberately in the second half of
    /// the IST day, where UTC-vs-IST day boundaries diverge.
    let now = Date(timeIntervalSince1970: 1786276800)

    private func task(_ title: String,
                      due: TimeInterval?,
                      priority: Priority = .normal,
                      status: TaskStatus = .pending) -> Task {
        Task(id: UUID().uuidString, title: title,
             dueAt: due.map { now.addingTimeInterval($0) },
             priority: priority, status: status)
    }

    @Test func testOverdueTasksAreBucketedFirst() {
        let summary = TodayPlanner.summarize(
            tasks: [task("later", due: 3600), task("overdue", due: -3600)], now: now)

        #expect(summary.buckets.first?.bucket == .overdue)
        #expect(summary.overdueCount == 1)
        #expect(summary.needsAttention)
    }

    @Test func testOverdueSortsMostOverdueFirst() {
        let summary = TodayPlanner.summarize(
            tasks: [task("1h", due: -3600), task("5h", due: -18000)], now: now)

        #expect(summary.buckets.first?.tasks.first?.title == "5h")
    }

    @Test func testCompletedTasksAreExcluded() {
        let summary = TodayPlanner.summarize(
            tasks: [task("done", due: -3600, status: .done),
                    task("dropped", due: -3600, status: .dropped)], now: now)

        #expect(summary.overdueCount == 0)
        #expect(summary.buckets.isEmpty)
    }

    @Test func testUndatedTasksGoToSomeday() {
        let summary = TodayPlanner.summarize(tasks: [task("someday", due: nil)], now: now)
        #expect(summary.buckets.first?.bucket == .noDate)
    }

    @Test func testUndatedTasksSortByPriority() {
        let summary = TodayPlanner.summarize(
            tasks: [task("low", due: nil, priority: .low),
                    task("must", due: nil, priority: .must)], now: now)

        #expect(summary.buckets.first?.tasks.first?.title == "must")
    }

    @Test func testDayBoundariesUseISTNotUTC() {
        // now = 17:30 IST. +7h is 00:30 IST *tomorrow*, but still the same
        // UTC day — bucketing on UTC would wrongly call this "today".
        let summary = TodayPlanner.summarize(tasks: [task("tomorrow early", due: 7 * 3600)], now: now)

        let todayTitles = summary.buckets.first { $0.bucket == .dueToday }?.tasks.map(\.title) ?? []
        #expect(!todayTitles.contains("tomorrow early"),
                "IST day boundary must be respected, not UTC's")
    }

    @Test func testTaskLaterTodayIsBucketedAsToday() {
        // 17:30 IST + 2h = 19:30 IST, same IST day.
        let summary = TodayPlanner.summarize(tasks: [task("dinner", due: 2 * 3600)], now: now)
        #expect(summary.buckets.first?.bucket == .dueToday)
    }

    @Test func testHighestLevelIsTracked() {
        let t = Task(id: "1", title: "critical", dueAt: now.addingTimeInterval(-7200),
                     priority: .must, escalationLevel: 3)
        #expect(TodayPlanner.summarize(tasks: [t], now: now).highestLevel == 3)
    }

    // MARK: - Relative labels

    @Test func testRelativeLabelForFuture() {
        #expect(TodayPlanner.relativeLabel(for: now.addingTimeInterval(300), now: now) == "in 5m")
        #expect(TodayPlanner.relativeLabel(for: now.addingTimeInterval(7200), now: now) == "in 2h")
    }

    @Test func testRelativeLabelForOverdue() {
        #expect(TodayPlanner.relativeLabel(for: now.addingTimeInterval(-7200), now: now)
                == "2h overdue")
    }

    @Test func testRelativeLabelForNow() {
        #expect(TodayPlanner.relativeLabel(for: now, now: now) == "now")
    }

    // MARK: - Snapshot

    @Test func testSnapshotAgeLabels() {
        let snap = Snapshot(tasks: [], capturedAt: now)
        #expect(snap.ageLabel(now: now.addingTimeInterval(30)) == "just now")
        #expect(snap.ageLabel(now: now.addingTimeInterval(600)) == "10m ago")
        #expect(snap.ageLabel(now: now.addingTimeInterval(7200)) == "2h ago")
    }

    @Test func testMemorySnapshotStoreRoundTrip() {
        let store = MemorySnapshotStore()
        #expect((store.load()) == nil)

        store.save(Snapshot(tasks: [task("cached", due: nil)], capturedAt: now))
        #expect(store.load()?.tasks.first?.title == "cached")
    }
}
