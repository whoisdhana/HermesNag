import Foundation

/// L0–L3 policy — the client's independent view of escalation.
///
/// The server also computes a level (`escalation_level` on the wire). We don't
/// blindly trust it: the client may be running from a cached snapshot with a
/// stale server level, and the client is the only one that knows local
/// conditions (screen locked, presenting, Focus). The rule is
/// **the lower of the two wins** — the server can't force a takeover the
/// client thinks is unwarranted, and vice versa.

public enum EscalationLevel: Int, Comparable, Sendable, CaseIterable {
    case ambient = 0   // L0 — menu bar only
    case playful = 1   // L1 — floating panel, bottom-right
    case annoyed = 2   // L2 — centred panel, sound, snooze cooldown
    case takeover = 3  // L3 — full-screen (M4; the engine can emit it now)

    public static func < (a: EscalationLevel, b: EscalationLevel) -> Bool {
        a.rawValue < b.rawValue
    }
}

public enum Escalation {
    /// Thresholds from the spec.
    public static let ambientLead: TimeInterval = 15 * 60
    public static let annoyedOverdue: TimeInterval = 30 * 60
    public static let takeoverOverdue: TimeInterval = 2 * 3600

    /// L1 auto-dismisses after 30s and counts as ignored.
    public static let playfulAutoDismiss: TimeInterval = 30

    /// L2's snooze button is disabled for 5s so it can't be reflex-dismissed.
    public static let annoyedSnoozeCooldown: TimeInterval = 5

    /// Level for a task, computed locally.
    public static func level(for task: Task, now: Date) -> EscalationLevel {
        guard task.isOpen, let due = task.dueAt else { return .ambient }

        // A snoozed task is silent until its snooze expires.
        if task.status == .snoozed, let until = task.snoozeUntil, now < until {
            return .ambient
        }

        guard now >= due else { return .ambient }
        let overdue = now.timeIntervalSince(due)

        // L3 is gated on `must` (or an explicit no-escape flag). A low or
        // normal task must never take over the screen, however long ignored.
        if task.priority == .must || task.noEscape {
            if task.noEscape || task.ignoreCount >= 3 || overdue >= takeoverOverdue {
                return .takeover
            }
        }

        if task.ignoreCount >= 1 || task.snoozeCount >= 2 || overdue >= annoyedOverdue {
            return .annoyed
        }

        return .playful
    }

    /// Reconciles the local level with the server's, taking the lower.
    public static func reconciled(for task: Task, now: Date) -> EscalationLevel {
        let local = level(for: task, now: now)
        let server = EscalationLevel(rawValue: task.escalationLevel) ?? .ambient
        return min(local, server == .ambient ? local : server)
    }

    /// Is this task within the L0 "coming up" window?
    public static func isAmbient(task: Task, now: Date) -> Bool {
        guard task.isOpen, let due = task.dueAt, now < due else { return false }
        return due.timeIntervalSince(now) <= ambientLead
    }
}

/// Mascot mood, driven by escalation and streak.
public enum MascotMood: String, Sendable {
    case idle, cheerful, sulking, glaring, ecstatic

    public static func forLevel(_ level: EscalationLevel) -> MascotMood {
        switch level {
        case .ambient: return .idle
        case .playful: return .cheerful
        case .annoyed: return .sulking
        case .takeover: return .glaring
        }
    }

    /// SF Symbol standing in for a sprite. The spec allows Lottie only if
    /// SF Symbols genuinely can't do it — these can, for now.
    public var symbol: String {
        switch self {
        case .idle: return "moon.zzz"
        case .cheerful: return "face.smiling"
        case .sulking: return "face.dashed"
        case .glaring: return "exclamationmark.triangle.fill"
        case .ecstatic: return "party.popper"
        }
    }
}
