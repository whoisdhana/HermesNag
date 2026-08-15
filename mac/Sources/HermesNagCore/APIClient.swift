import Foundation

/// Talks to the server through the SSH tunnel on 127.0.0.1.
///
/// M2 is read-only: list tasks, fetch health/stats/due. Mutating calls
/// (complete/snooze/drop) arrive in M3 along with the reminder engine.

public actor APIClient {
    public struct Config: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval

        public init(baseURL: URL = URL(string: "http://127.0.0.1:8787")!,
                    timeout: TimeInterval = 10) {
            self.baseURL = baseURL
            self.timeout = timeout
        }
    }

    public enum ClientError: Error, LocalizedError {
        case noToken(String)
        case http(Int, String)
        case transport(String)
        case decoding(String)

        public var errorDescription: String? {
            switch self {
            case .noToken(let m): return m
            case .http(let code, let msg): return "HTTP \(code): \(msg)"
            case .transport(let m): return m
            case .decoding(let m): return "Bad response: \(m)"
            }
        }

        /// Distinguishes "the tunnel is down" from "the server said no", so
        /// the UI can point at the right problem.
        public var looksLikeTunnelDown: Bool {
            if case .transport = self { return true }
            return false
        }
    }

    private let config: Config
    private let session: URLSession
    private let tokenProvider: @Sendable () throws -> String

    public init(config: Config = Config(),
                session: URLSession? = nil,
                tokenProvider: @escaping @Sendable () throws -> String = { try Keychain.readToken() }) {
        self.config = config
        self.tokenProvider = tokenProvider

        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = config.timeout
            cfg.waitsForConnectivity = false  // fail fast; the supervisor retries
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Build the URL for a path that may carry a query string.
    ///
    /// `appendingPathComponent` percent-encodes `?`, so
    /// "habits?active=true" became the literal path "/habits%3Factive=true"
    /// → 404 on every call. Habits were silently dead in the app because of
    /// this: no section in the widget, no notifications.
    nonisolated func url(for path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1)
        var url = config.baseURL.appendingPathComponent(String(parts[0]))
        if parts.count == 2,
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.percentEncodedQuery = String(parts[1])
            url = comps.url ?? url
        }
        return url
    }

    private func request(_ path: String,
                         method: String = "GET",
                         body: [String: Any]? = nil,
                         authenticated: Bool = true) throws -> URLRequest {
        var req = URLRequest(url: url(for: path))
        req.timeoutInterval = config.timeout
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        if authenticated {
            let token: String
            do {
                token = try tokenProvider()
            } catch {
                throw ClientError.noToken(error.localizedDescription)
            }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func perform<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.transport("no HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            // The server always sends {error:{code,message}} — surface the
            // real message rather than a bare status code.
            if let apiErr = try? JSON.decoder().decode(APIError.self, from: data) {
                throw ClientError.http(http.statusCode, apiErr.error.message)
            }
            throw ClientError.http(http.statusCode,
                                   String(data: data, encoding: .utf8) ?? "unknown error")
        }

        do {
            return try JSON.decoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(error.localizedDescription)
        }
    }

    /// Health needs no token — useful for distinguishing "tunnel up but token
    /// wrong" from "tunnel down entirely".
    public func health() async throws -> Health {
        try await perform(request("health", authenticated: false), as: Health.self)
    }

    public func tasks() async throws -> [Task] {
        try await perform(request("tasks"), as: TaskList.self).tasks
    }

    public func due() async throws -> DueResponse {
        try await perform(request("due"), as: DueResponse.self)
    }

    public func stats() async throws -> Stats {
        try await perform(request("stats"), as: Stats.self)
    }

    // MARK: - Mutations (M3)

    // MARK: - Habits

    /// Presence is passed to the server because only the Mac knows whether
    /// the user is actually at the machine.
    private func presenceQuery(_ presence: (active: Bool, minutes: Int, locked: Bool)) -> String {
        "active=\(presence.active)&continuous_minutes=\(presence.minutes)"
            + "&screen_locked=\(presence.locked)"
    }

    public func habits(presence: (active: Bool, minutes: Int, locked: Bool)) async throws -> [Habit] {
        try await perform(request("habits?" + presenceQuery(presence)), as: HabitList.self).habits
    }

    public func habitsDue(presence: (active: Bool, minutes: Int, locked: Bool)) async throws -> [Habit] {
        try await perform(request("habits/due?" + presenceQuery(presence)),
                          as: HabitsDue.self).due
    }

    @discardableResult
    public func completeHabit(id: String) async throws -> Habit {
        try await perform(request("habits/\(id)/done", method: "POST"), as: Habit.self)
    }

    public func habitFired(id: String) async throws {
        _ = try await perform(request("habits/\(id)/fired", method: "POST"), as: Habit.self)
    }

    /// Create the default habit set. Idempotent server-side.
    @discardableResult
    public func seedHabits() async throws -> Int {
        try await perform(request("habits/seed", method: "POST"), as: SeedResult.self).count
    }

    /// Create a habit from natural language ("meditate daily", "walk every 2h").
    @discardableResult
    public func createHabit(raw: String) async throws -> Habit {
        try await perform(request("habits", method: "POST", body: ["raw": raw]), as: Habit.self)
    }

    /// Create from natural language — the server parses it.
    @discardableResult
    public func create(raw: String) async throws -> Task {
        try await perform(request("tasks", method: "POST", body: ["raw": raw]), as: Task.self)
    }

    @discardableResult
    public func complete(taskID: String) async throws -> CompletionResult {
        try await perform(request("tasks/\(taskID)/complete", method: "POST"),
                          as: CompletionResult.self)
    }

    @discardableResult
    public func snooze(taskID: String, minutes: Int) async throws -> Task {
        try await perform(request("tasks/\(taskID)/snooze", method: "POST",
                                  body: ["minutes": minutes]), as: Task.self)
    }

    /// Undo a completion — powers the 5-second Undo chip.
    @discardableResult
    public func reopen(taskID: String) async throws -> Task {
        try await perform(request("tasks/\(taskID)/reopen", method: "POST"), as: Task.self)
    }

    @discardableResult
    public func drop(taskID: String) async throws -> Task {
        try await perform(request("tasks/\(taskID)/drop", method: "POST"), as: Task.self)
    }

    /// Tells the server what the client actually displayed. `ignored` is what
    /// drives escalation, so the ladder reflects real popups rather than what
    /// the server merely intended to show.
    public func ack(taskID: String, level: Int, action: String) async throws {
        _ = try await perform(request("tasks/\(taskID)/ack", method: "POST",
                                      body: ["level": level, "action": action]),
                              as: Task.self)
    }
}

public struct CompletionResult: Codable, Sendable {
    public let task: Task
    public let xpAwarded: Int
    public let streak: Int
    public let mascotMood: String

    enum CodingKeys: String, CodingKey {
        case task, streak
        case xpAwarded = "xp_awarded"
        case mascotMood = "mascot_mood"
    }
}
