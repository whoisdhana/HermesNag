import Testing
import Foundation
@testable import HermesNagCore

/// Rate limiting and suppression reasons for L3.
///
/// The takeover is the only feature that can seize the whole screen, so these
/// guards get the same treatment as the timezone rule: assert the refusal
/// explicitly rather than inferring it from something not happening.
@Suite struct TakeoverPolicyTests {
    init() {
        // These tests assert IST-vs-UTC boundary behaviour specifically.
        UserDefaults.standard.set("Asia/Kolkata", forKey: "displayTimeZone")
    }

    let T0 = Date(timeIntervalSince1970: 1786539600)  // 2026-08-12T13:00:00Z = 18:30 IST
    let policy = TakeoverPolicy()

    private func none(_ ledger: TakeoverLedger = TakeoverLedger(),
                      now: Date? = nil,
                      presenting: Bool = false,
                      kill: Bool = false,
                      locked: Bool = false) -> TakeoverSuppression? {
        policy.suppression(now: now ?? T0, ledger: ledger,
                           isPresenting: presenting, killSwitch: kill, screenLocked: locked)
    }

    // MARK: - Clean pass

    @Test func firstTakeoverIsAllowed() {
        #expect(none() == nil)
    }

    // MARK: - Cooldown (45 min)

    @Test func secondTakeoverWithinCooldownIsBlocked() {
        let ledger = TakeoverLedger(firedAt: [T0.addingTimeInterval(-10 * 60)])
        #expect(none(ledger) == .cooldown)
    }

    @Test func takeoverAllowedAfterCooldownExpires() {
        let ledger = TakeoverLedger(firedAt: [T0.addingTimeInterval(-46 * 60)])
        #expect(none(ledger) == nil)
    }

    @Test func cooldownBoundaryIsExclusive() {
        // Exactly 45 minutes later is allowed; a second earlier is not.
        let at45 = TakeoverLedger(firedAt: [T0.addingTimeInterval(-45 * 60)])
        #expect(none(at45) == nil)

        let justUnder = TakeoverLedger(firedAt: [T0.addingTimeInterval(-45 * 60 + 1)])
        #expect(none(justUnder) == .cooldown)
    }

    @Test func cooldownRemainingCountsDown() {
        let ledger = TakeoverLedger(firedAt: [T0.addingTimeInterval(-15 * 60)])
        #expect(policy.cooldownRemaining(now: T0, ledger: ledger) == 30 * 60)
    }

    @Test func cooldownRemainingIsZeroWithNoHistory() {
        #expect(policy.cooldownRemaining(now: T0, ledger: TakeoverLedger()) == 0)
    }

    // MARK: - Daily limit

    @Test func fourthTakeoverInADayIsBlocked() {
        // Three earlier today, all outside the cooldown window.
        let ledger = TakeoverLedger(firedAt: [
            T0.addingTimeInterval(-5 * 3600),
            T0.addingTimeInterval(-4 * 3600),
            T0.addingTimeInterval(-3 * 3600),
        ])
        #expect(none(ledger) == .dailyLimit)
    }

    @Test func threeADayIsStillAllowedOnTheThird() {
        let ledger = TakeoverLedger(firedAt: [
            T0.addingTimeInterval(-5 * 3600),
            T0.addingTimeInterval(-4 * 3600),
        ])
        #expect(none(ledger) == nil)
    }

    /// The daily limit must reset on the *user's* midnight, not UTC's.
    ///
    /// T0 is 13:00Z = 18:30 IST on Aug 12. Fourteen hours earlier is 23:00Z on
    /// Aug **11** but 04:30 IST on Aug **12** — the same IST day, a different
    /// UTC one. So a UTC calendar counts 0 today and wrongly allows a fourth
    /// takeover; IST counts 3 and correctly blocks it. This is the exact case
    /// that distinguishes the two, and it fails if anyone swaps in UTC.
    @Test func dailyLimitUsesISTDayBoundariesNotUTC() {
        let earlyToday = T0.addingTimeInterval(-14 * 3600)  // 04:30 IST, same IST day
        let ledger = TakeoverLedger(firedAt: [earlyToday, earlyToday, earlyToday])

        #expect(ledger.countToday(now: T0, calendar: .hermesNag) == 3,
                "04:30 IST is today in Asia/Kolkata even though it's yesterday in UTC")
        #expect(none(ledger) == .dailyLimit)
    }

    @Test func genuinelyYesterdayDoesNotCountAgainstToday() {
        let yesterday = T0.addingTimeInterval(-30 * 3600)
        let ledger = TakeoverLedger(firedAt: [yesterday, yesterday, yesterday])

        #expect(ledger.countToday(now: T0, calendar: .hermesNag) == 0)
        #expect(none(ledger) == nil)
    }

    @Test func remainingTodayReportsBudget() {
        let ledger = TakeoverLedger(firedAt: [T0.addingTimeInterval(-3 * 3600)])
        #expect(policy.remainingToday(now: T0, ledger: ledger) == 2)
    }

    @Test func remainingTodayNeverGoesNegative() {
        let many = TakeoverLedger(firedAt: Array(repeating: T0.addingTimeInterval(-3600), count: 9))
        #expect(policy.remainingToday(now: T0, ledger: many) == 0)
    }

    // MARK: - Valve precedence

    @Test func screenLockedWinsOverEverything() {
        // Locked is the most actionable explanation, and the spec says queue
        // for unlock rather than fire.
        let full = TakeoverLedger(firedAt: [T0.addingTimeInterval(-60)])
        #expect(none(full, presenting: true, kill: true, locked: true) == .screenLocked)
    }

    @Test func killSwitchWinsOverPresentingAndCooldown() {
        let full = TakeoverLedger(firedAt: [T0.addingTimeInterval(-60)])
        #expect(none(full, presenting: true, kill: true) == .killSwitch)
    }

    @Test func presentingWinsOverCooldown() {
        // "You're on a call" is more useful than "cooldown" when both hold.
        let full = TakeoverLedger(firedAt: [T0.addingTimeInterval(-60)])
        #expect(none(full, presenting: true) == .presenting)
    }

    @Test func everySuppressionReasonHasAUserMessage() {
        for reason in TakeoverSuppression.allCases {
            #expect(!reason.userMessage.isEmpty)
        }
    }

    // MARK: - Ledger bookkeeping

    @Test func recordingPrunesAncientEntries() {
        var ledger = TakeoverLedger(firedAt: [T0.addingTimeInterval(-72 * 3600)])
        ledger.record(T0)
        #expect(ledger.firedAt.count == 1, "entries older than 48h can't affect any limit")
    }

    @Test func ledgerRoundTripsThroughJSON() throws {
        // It's persisted to UserDefaults so a relaunch can't reset the budget.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(TakeoverLedger(firedAt: [T0]))
        let decoded = try JSON.decoder().decode(TakeoverLedger.self, from: data)
        #expect(decoded.firedAt.count == 1)
    }

    @Test func policyReadsOverridesFromDefaults() {
        let defaults = UserDefaults(suiteName: "hermesnag.tests.policy")!
        defaults.set(120.0, forKey: "takeoverCooldownSeconds")
        defaults.set(7, forKey: "takeoverMaxPerDay")

        let custom = TakeoverPolicy.fromDefaults(defaults)
        #expect(custom.cooldown == 120)
        #expect(custom.maxPerDay == 7)

        defaults.removePersistentDomain(forName: "hermesnag.tests.policy")
    }

    @Test func policyFallsBackToSpecDefaults() {
        let empty = UserDefaults(suiteName: "hermesnag.tests.empty")!
        empty.removePersistentDomain(forName: "hermesnag.tests.empty")
        let p = TakeoverPolicy.fromDefaults(empty)
        #expect(p.cooldown == 45 * 60)
        #expect(p.maxPerDay == 3)
    }
}

/// The engine's end of the valves: L3 must downgrade, not vanish.
@Suite struct TakeoverEngineIntegrationTests {

    let T0 = Date(timeIntervalSince1970: 1786539600)

    private func mustTask() -> Task {
        Task(id: "t1", title: "Ship the thing",
             dueAt: T0.addingTimeInterval(-3 * 3600),  // 3h overdue
             priority: .must)
    }

    private func levels(_ actions: [ReminderAction]) -> [EscalationLevel] {
        actions.compactMap { if case .present(_, let l, _) = $0 { return l } else { return nil } }
    }

    private func reasons(_ actions: [ReminderAction]) -> [TakeoverSuppression] {
        actions.compactMap { if case .takeoverSuppressed(_, let r) = $0 { return r } else { return nil } }
    }

    @Test func overdueMustTaskReachesTakeover() {
        let actions = ReminderEngine().decide(tasks: [mustTask()], now: T0, state: UserState())
        #expect(levels(actions) == [.takeover])
    }

    @Test func firedTakeoverIsAnnounced() {
        // The driver needs this to update the ledger; without it the rate
        // limits would never engage.
        let actions = ReminderEngine().decide(tasks: [mustTask()], now: T0, state: UserState())
        #expect(actions.contains(.takeoverFired(taskID: "t1")))
    }

    @Test func presentingDowngradesToL2WithAReason() {
        var state = UserState()
        state.isPresenting = true
        let actions = ReminderEngine().decide(tasks: [mustTask()], now: T0, state: state)

        #expect(levels(actions) == [.annoyed], "downgrade, never silence")
        #expect(reasons(actions) == [.presenting])
    }

    @Test func killSwitchDowngradesWithAReason() {
        var state = UserState()
        state.takeoverDisabled = true
        let actions = ReminderEngine().decide(tasks: [mustTask()], now: T0, state: state)

        #expect(levels(actions) == [.annoyed])
        #expect(reasons(actions) == [.killSwitch])
    }

    @Test func cooldownDowngradesWithAReason() {
        var state = UserState()
        state.takeoverLedger = TakeoverLedger(firedAt: [T0.addingTimeInterval(-5 * 60)])
        let actions = ReminderEngine().decide(tasks: [mustTask()], now: T0, state: state)

        #expect(levels(actions) == [.annoyed])
        #expect(reasons(actions) == [.cooldown])
    }

    @Test func suppressedTakeoverEmitsNoFiredAction() {
        var state = UserState()
        state.isPresenting = true
        let actions = ReminderEngine().decide(tasks: [mustTask()], now: T0, state: state)
        #expect(!actions.contains(.takeoverFired(taskID: "t1")))
    }

    @Test func normalPriorityNeverProducesASuppressionReason() {
        // A normal task was never a takeover candidate, so there's nothing to
        // suppress — it should reach L2 on its own merits, silently.
        let normal = Task(id: "t2", title: "tidy up",
                          dueAt: T0.addingTimeInterval(-3 * 3600), priority: .normal)
        let actions = ReminderEngine().decide(tasks: [normal], now: T0, state: UserState())

        #expect(levels(actions) == [.annoyed])
        #expect(reasons(actions).isEmpty)
    }
}
