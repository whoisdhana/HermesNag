import AppKit
import CoreGraphics
import HermesNagCore

/// Tracks continuous laptop use, so "stand up" fires because you've been
/// *sitting* — not merely because 50 minutes passed on the wall clock.
///
/// A nudge that arrives while you're out for lunch is noise, and noise teaches
/// you to ignore the nudges that matter.
@MainActor
final class PresenceTracker {
    /// Idle longer than this counts as a break and resets the sitting timer.
    private let breakThreshold: TimeInterval = 5 * 60

    private var sittingSince: Date?
    private var lastSample: Date?

    /// Seconds since the last keyboard or mouse event.
    var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
    }

    var isScreenLocked: Bool {
        SystemState.isScreenLocked
    }

    /// Call once per tick.
    func sample(now: Date = Date()) {
        defer { lastSample = now }

        let idle = idleSeconds
        let away = idle >= breakThreshold || isScreenLocked

        if away {
            // Took a break — the next sitting stretch starts fresh.
            sittingSince = nil
            return
        }

        if sittingSince == nil {
            sittingSince = now
        }
    }

    /// Continuous minutes at the machine.
    var continuousMinutes: Int {
        guard let sittingSince else { return 0 }
        return Int(Date().timeIntervalSince(sittingSince) / 60)
    }

    var isActive: Bool {
        idleSeconds < breakThreshold && !isScreenLocked
    }

    /// Acknowledging a break (standing up) restarts the clock immediately,
    /// rather than waiting for the idle threshold to notice.
    func recordBreak() {
        sittingSince = nil
    }

    var snapshot: (active: Bool, minutes: Int, locked: Bool) {
        (isActive, continuousMinutes, isScreenLocked)
    }
}
