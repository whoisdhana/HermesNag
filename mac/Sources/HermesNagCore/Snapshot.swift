import Foundation

/// Local cache of the last good server state.
///
/// Spec: "If the tunnel is down, the app still fires reminders from its local
/// cached snapshot... Offline must degrade, not fail." M2 only reads and
/// displays it; M3's reminder engine will fire from it.

/// File logger. NSLog/os_log output from an ad-hoc-signed LSUIElement bundle
/// doesn't reliably reach `log show`, which cost real debugging time — an
/// empty log read as "the event didn't happen" when it simply wasn't captured.
public enum DebugLog {
    private static let lock = NSLock()

    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("HermesNag", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("debug.log")
    }

    /// Rotate above this size; keep exactly one `.old` generation.
    /// An append-only log with no cap grows forever on a machine that never
    /// reboots — small leak, guaranteed to matter eventually.
    static let rotateAt = 512 * 1024

    public static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }

        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > rotateAt {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

public struct Snapshot: Codable, Sendable {
    public let tasks: [Task]
    public let capturedAt: Date

    public init(tasks: [Task], capturedAt: Date) {
        self.tasks = tasks
        self.capturedAt = capturedAt
    }

    public func age(now: Date) -> TimeInterval {
        now.timeIntervalSince(capturedAt)
    }

    /// "just now" / "5m ago" — shown when serving stale data, so the popover
    /// never silently presents an old list as current.
    public func ageLabel(now: Date) -> String {
        let seconds = age(now: now)
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60))m ago"
        case ..<86400: return "\(Int(seconds / 3600))h ago"
        default: return "\(Int(seconds / 86400))d ago"
        }
    }
}

public protocol SnapshotStoring: Sendable {
    func load() -> Snapshot?
    func save(_ snapshot: Snapshot)
}

/// Persists to Application Support. Deliberately failure-tolerant: a cache
/// that can't be written must never take the app down.
public struct FileSnapshotStore: SnapshotStoring {
    private let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
                .appendingPathComponent("HermesNag", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.url = base.appendingPathComponent("snapshot.json")
        }
    }

    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSON.decoder().decode(Snapshot.self, from: data)
    }

    public func save(_ snapshot: Snapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// In-memory store for tests.
public final class MemorySnapshotStore: SnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: Snapshot?

    public init(initial: Snapshot? = nil) { self.snapshot = initial }

    public func load() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func save(_ snapshot: Snapshot) {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
    }
}
