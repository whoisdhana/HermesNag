import Foundation

/// Durable queue for mutations made while the tunnel was down.
///
/// Spec: "the app still fires reminders from its local cached snapshot, and
/// queues completions to sync later." Clicking Done must feel instant and must
/// not be lost because ssh happened to be reconnecting.

public enum PendingAction: Codable, Sendable, Equatable {
    case complete(taskID: String)
    case snooze(taskID: String, minutes: Int)
    case drop(taskID: String)
    case ack(taskID: String, level: Int, action: String)

    public var taskID: String {
        switch self {
        case .complete(let id), .drop(let id): return id
        case .snooze(let id, _): return id
        case .ack(let id, _, _): return id
        }
    }

    /// Acks are telemetry — losing one is survivable. A completion is the
    /// user's actual intent and must never be dropped silently.
    public var isCritical: Bool {
        if case .ack = self { return false }
        return true
    }
}

public struct QueuedAction: Codable, Sendable, Equatable {
    public let action: PendingAction
    public let queuedAt: Date
    public var attempts: Int

    public init(action: PendingAction, queuedAt: Date, attempts: Int = 0) {
        self.action = action
        self.queuedAt = queuedAt
        self.attempts = attempts
    }
}

public protocol ActionQueueStoring: Sendable {
    func load() -> [QueuedAction]
    func save(_ actions: [QueuedAction])
}

public struct FileActionQueueStore: ActionQueueStoring {
    private let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
                .appendingPathComponent("HermesNag", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.url = base.appendingPathComponent("pending-actions.json")
        }
    }

    public func load() -> [QueuedAction] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSON.decoder().decode([QueuedAction].self, from: data)) ?? []
    }

    public func save(_ actions: [QueuedAction]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(actions) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public final class MemoryActionQueueStore: ActionQueueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [QueuedAction] = []

    public init(initial: [QueuedAction] = []) { self.actions = initial }

    public func load() -> [QueuedAction] {
        lock.lock(); defer { lock.unlock() }
        return actions
    }

    public func save(_ actions: [QueuedAction]) {
        lock.lock(); defer { lock.unlock() }
        self.actions = actions
    }
}

/// Queue policy — pure, so retry/expiry rules are unit-testable.
public enum ActionQueuePolicy {
    /// Give up on a non-critical action after this many failures.
    public static let maxAttempts = 5
    /// Drop anything older than this; a week-old ack is meaningless.
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Collapse redundant actions. Completing a task makes an earlier snooze
    /// for the same task pointless, and re-sending it would resurrect a task
    /// the user already finished.
    public static func coalesce(_ queued: [QueuedAction]) -> [QueuedAction] {
        var completedOrDropped = Set<String>()
        for item in queued {
            switch item.action {
            case .complete(let id), .drop(let id): completedOrDropped.insert(id)
            default: break
            }
        }

        var seenTerminal = Set<String>()
        var out: [QueuedAction] = []

        for item in queued {
            switch item.action {
            case .complete(let id), .drop(let id):
                // Keep only the first terminal action per task.
                if seenTerminal.contains(id) { continue }
                seenTerminal.insert(id)
                out.append(item)
            case .snooze(let id, _):
                // A snooze superseded by a completion is dead weight.
                if completedOrDropped.contains(id) { continue }
                out.append(item)
            case .ack:
                out.append(item)
            }
        }
        return out
    }

    /// A critical action that has failed this many times is almost certainly
    /// failing permanently. 4,514 attempts were observed live before this
    /// existed — "never give up" turned into "spin forever".
    public static let criticalMaxAttempts = 50

    public static func shouldDrop(_ item: QueuedAction, now: Date) -> Bool {
        if now.timeIntervalSince(item.queuedAt) > maxAge { return true }
        if !item.action.isCritical && item.attempts >= maxAttempts { return true }
        if item.action.isCritical && item.attempts >= criticalMaxAttempts { return true }
        return false
    }
}
