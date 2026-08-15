import Foundation

/// Wire types mirroring the server's JSON. Field names match the API exactly
/// (docs/01-api.md) so no CodingKeys gymnastics are needed.

public enum Priority: String, Codable, Sendable, CaseIterable {
    case low, normal, high, must
}

public enum TaskStatus: String, Codable, Sendable {
    case pending, snoozed, done, dropped
}

public struct Task: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let notes: String?
    /// Canonical instant, always UTC with an explicit offset on the wire.
    public let dueAt: Date?
    /// Server-rendered IST string, display only. The client never parses this
    /// to compute anything — `dueAt` is the single source of truth.
    public let dueAtLocal: String?
    public let recurrence: String?
    public let priority: Priority
    public let tags: [String]
    public let status: TaskStatus
    public let snoozeUntil: Date?
    public let escalationLevel: Int
    public let ignoreCount: Int
    public let snoozeCount: Int
    public let noEscape: Bool
    public let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, notes, recurrence, priority, tags, status
        case dueAt = "due_at"
        case dueAtLocal = "due_at_local"
        case snoozeUntil = "snooze_until"
        case escalationLevel = "escalation_level"
        case ignoreCount = "ignore_count"
        case snoozeCount = "snooze_count"
        case noEscape = "no_escape"
        case completedAt = "completed_at"
    }

    public init(
        id: String, title: String, notes: String? = nil, dueAt: Date? = nil,
        dueAtLocal: String? = nil, recurrence: String? = nil,
        priority: Priority = .normal, tags: [String] = [],
        status: TaskStatus = .pending, snoozeUntil: Date? = nil,
        escalationLevel: Int = 0, ignoreCount: Int = 0, snoozeCount: Int = 0,
        noEscape: Bool = false, completedAt: Date? = nil
    ) {
        self.id = id; self.title = title; self.notes = notes
        self.dueAt = dueAt; self.dueAtLocal = dueAtLocal
        self.recurrence = recurrence; self.priority = priority
        self.tags = tags; self.status = status; self.snoozeUntil = snoozeUntil
        self.escalationLevel = escalationLevel; self.ignoreCount = ignoreCount
        self.snoozeCount = snoozeCount; self.noEscape = noEscape
        self.completedAt = completedAt
    }

    public var isOpen: Bool { status == .pending || status == .snoozed }

    // Optimistic local edits. The server remains the source of truth — these
    // just keep the UI honest until the next refresh confirms it.

    public func completedLocally(now: Date = Date()) -> Task {
        copy(status: .done, completedAt: now)
    }

    public func droppedLocally() -> Task {
        copy(status: .dropped)
    }

    public func snoozedLocally(minutes: Int, now: Date = Date()) -> Task {
        copy(status: .snoozed,
             snoozeUntil: now.addingTimeInterval(TimeInterval(minutes * 60)),
             snoozeCount: snoozeCount + 1)
    }

    private func copy(status: TaskStatus? = nil,
                      snoozeUntil: Date?? = nil,
                      snoozeCount: Int? = nil,
                      completedAt: Date? = nil) -> Task {
        Task(id: id, title: title, notes: notes, dueAt: dueAt, dueAtLocal: dueAtLocal,
             recurrence: recurrence, priority: priority, tags: tags,
             status: status ?? self.status,
             snoozeUntil: snoozeUntil ?? self.snoozeUntil,
             escalationLevel: escalationLevel, ignoreCount: ignoreCount,
             snoozeCount: snoozeCount ?? self.snoozeCount,
             noEscape: noEscape, completedAt: completedAt ?? self.completedAt)
    }

    public func isOverdue(now: Date) -> Bool {
        guard let dueAt, isOpen else { return false }
        return now >= dueAt
    }
}

public struct TaskList: Codable, Sendable {
    public let tasks: [Task]
}

/// A recurring nudge — drink water, stand up, rest your eyes.
/// Unlike a Task it has no deadline and is never finished; it comes round again.
public struct Habit: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let intervalMinutes: Int
    public let requiresPresence: Bool
    public let escalates: Bool
    public let enabled: Bool
    public let streak: Int
    public let secondsUntilDue: Int
    public let isDue: Bool
    public let level: Int
    public let inActiveHours: Bool
    public let nagLine: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, streak, level
        case intervalMinutes = "interval_minutes"
        case requiresPresence = "requires_presence"
        case escalates
        case secondsUntilDue = "seconds_until_due"
        case isDue = "is_due"
        case inActiveHours = "in_active_hours"
        case nagLine = "nag_line"
    }

    /// "in 12m" / "now" — for the widget's countdown.
    public var countdown: String {
        if isDue { return "now" }
        let mins = secondsUntilDue / 60
        if mins < 1 { return "<1m" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h\(mins % 60 > 0 ? "\(mins % 60)m" : "")"
    }
}

public struct HabitList: Codable, Sendable {
    public let habits: [Habit]
}

public struct HabitsDue: Codable, Sendable {
    public let due: [Habit]
    public let count: Int
}

public struct SeedResult: Codable, Sendable {
    public let created: [String]
    public let count: Int
}

public struct DueItem: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let priority: Priority
    public let level: Int
    public let nagLine: String
    public let dueAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, priority, level
        case nagLine = "nag_line"
        case dueAt = "due_at"
    }
}

public struct DueResponse: Codable, Sendable {
    public let due: [DueItem]
    public let count: Int
}

public struct Health: Codable, Sendable {
    public let ok: Bool
    public let version: String
    public let dbOk: Bool
    public let hermesOk: Bool

    enum CodingKeys: String, CodingKey {
        case ok, version
        case dbOk = "db_ok"
        case hermesOk = "hermes_ok"
    }
}

public struct Stats: Codable, Sendable {
    public let streakDays: Int
    public let xp: Int
    public let xpLevel: Int
    public let completed7d: Int
    // Game layer (optional: tolerate an older server).
    public let pointsTotal: Int?
    public let pointsToday: Int?
    public let level: Int?
    public let levelName: String?
    public let nextLevelAt: Int?
    public let levelProgress: Double?
    public let perfectDays: Int?

    enum CodingKeys: String, CodingKey {
        case xp, level
        case streakDays = "streak_days"
        case xpLevel = "xp_level"
        case completed7d = "completed_7d"
        case pointsTotal = "points_total"
        case pointsToday = "points_today"
        case levelName = "level_name"
        case nextLevelAt = "next_level_at"
        case levelProgress = "level_progress"
        case perfectDays = "perfect_days"
    }
}

public struct APIError: Codable, Sendable, Error {
    public struct Detail: Codable, Sendable {
        public let code: String
        public let message: String
    }
    public let error: Detail
}

public enum JSON {
    /// The server always sends ISO-8601 with an explicit offset — the naive
    /// case is rejected server-side (correction C1), so `.iso8601` is safe here.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFractional.date(from: text) ?? plain.date(from: text) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "expected ISO-8601 with offset, got \(text)")
            )
        }
        return d
    }
}
