import Foundation

/// How today's tasks get grouped and ordered in the popover.
/// Pure functions of (tasks, now) — no view code, so it's unit-testable.

public enum TaskBucket: String, Sendable, CaseIterable {
    case overdue
    case dueToday
    case upcoming
    case noDate

    public var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .dueToday: return "Today"
        case .upcoming: return "Upcoming"
        case .noDate: return "Someday"
        }
    }
}

public struct TodaySummary: Sendable {
    public let buckets: [(bucket: TaskBucket, tasks: [Task])]
    public let overdueCount: Int
    public let dueTodayCount: Int
    public let highestLevel: Int

    /// True when something is overdue — drives the menu bar badge.
    public var needsAttention: Bool { overdueCount > 0 }
}

public enum TodayPlanner {
    /// Day boundaries use the user's zone (Asia/Kolkata), not UTC.
    /// "Due today" has to mean the user's today, or the popover lies.
    public static func summarize(
        tasks: [Task],
        now: Date,
        calendar: Calendar = .hermesNag
    ) -> TodaySummary {
        let open = tasks.filter(\.isOpen)

        var overdue: [Task] = []
        var today: [Task] = []
        var upcoming: [Task] = []
        var undated: [Task] = []

        for task in open {
            guard let due = task.dueAt else {
                undated.append(task)
                continue
            }
            if due <= now {
                overdue.append(task)
            } else if calendar.isDate(due, inSameDayAs: now) {
                today.append(task)
            } else {
                upcoming.append(task)
            }
        }

        // Most overdue first; then soonest.
        overdue.sort { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
        today.sort { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        upcoming.sort { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        undated.sort { priorityRank($0.priority) > priorityRank($1.priority) }

        var buckets: [(TaskBucket, [Task])] = []
        if !overdue.isEmpty { buckets.append((.overdue, overdue)) }
        if !today.isEmpty { buckets.append((.dueToday, today)) }
        if !upcoming.isEmpty { buckets.append((.upcoming, Array(upcoming.prefix(5)))) }
        if !undated.isEmpty { buckets.append((.noDate, Array(undated.prefix(5)))) }

        return TodaySummary(
            buckets: buckets,
            overdueCount: overdue.count,
            dueTodayCount: today.count,
            highestLevel: open.map(\.escalationLevel).max() ?? 0
        )
    }

    private static func priorityRank(_ p: Priority) -> Int {
        switch p {
        case .must: return 3
        case .high: return 2
        case .normal: return 1
        case .low: return 0
        }
    }

    /// "in 5m" / "2h overdue" — compact enough for a menu bar popover.
    public static func relativeLabel(for date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        let overdue = delta < 0
        let seconds = abs(delta)

        let text: String
        switch seconds {
        case ..<60:
            text = "now"
            return overdue ? "just now" : "now"
        case ..<3600:
            text = "\(Int(seconds / 60))m"
        case ..<86400:
            text = "\(Int(seconds / 3600))h"
        default:
            text = "\(Int(seconds / 86400))d"
        }
        return overdue ? "\(text) overdue" : "in \(text)"
    }
}

public extension Calendar {
    /// The user's display zone (defaults key `displayTimeZone`, falls back to
    /// the system zone). Storage stays UTC everywhere; ONLY day boundaries
    /// and rendering use this.
    static var hermesNag: Calendar {
        var cal = Calendar(identifier: .gregorian)
        if let id = UserDefaults.standard.string(forKey: "displayTimeZone"),
           let tz = TimeZone(identifier: id) {
            cal.timeZone = tz
        } else {
            cal.timeZone = .current
        }
        return cal
    }
}
