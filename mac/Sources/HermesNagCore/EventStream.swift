import Foundation

/// SSE consumer for `/events` — the push channel the spec calls primary:
/// "Polling is the fallback, never the primary." Until this existed the Mac
/// only polled, so a Hermes-created task took up to 30s to appear.
///
/// Split in two: `SSEParser` is a pure line-by-line frame parser (unit-tested
/// without any networking); `EventStream` owns the connection and reconnect.

/// One parsed server-sent event.
public struct SSEvent: Equatable, Sendable {
    public let name: String
    public let data: String
}

/// Incremental SSE frame parser. Feed it lines; it emits an event when the
/// frame's `data:` line arrives. Comment lines (": heartbeat") keep the
/// connection warm but never produce an event.
///
/// Emitting on `data:` rather than on the blank frame-terminator is
/// deliberate: Swift's `AsyncLineSequence` is known to swallow empty lines,
/// which would make a blank-delimited parser never fire. Our server writes
/// exactly one `data:` line per frame (events.py `sse_format`), so this is
/// both simpler and immune to that pitfall.
public struct SSEParser: Sendable {
    private var name = ""

    public init() {}

    public mutating func consume(line: String) -> SSEvent? {
        if line.isEmpty {
            name = ""            // frame boundary (when delivered at all)
            return nil
        }
        if line.hasPrefix(":") { return nil }  // comment / heartbeat

        if line.hasPrefix("event:") {
            name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            defer { name = "" }
            return SSEvent(name: name.isEmpty ? "message" : name,
                           data: String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// Owns the long-lived connection to `/events`, with reconnect using the same
/// Backoff policy as the tunnel (1s → 60s, jittered).
public actor EventStream {
    public enum State: Equatable, Sendable {
        case idle, connecting, connected, down
    }

    private let config: APIClient.Config
    private let tokenProvider: @Sendable () throws -> String
    private let backoff: Backoff
    private var task: _Concurrency.Task<Void, Never>?
    public private(set) var state: State = .idle

    /// Called on the events that matter; heartbeats and `hello` are absorbed.
    private let onEvent: @Sendable (SSEvent) -> Void
    private let onStateChange: @Sendable (State) -> Void

    public init(config: APIClient.Config = .init(),
                backoff: Backoff = Backoff(),
                tokenProvider: @escaping @Sendable () throws -> String = { try Keychain.readToken() },
                onEvent: @escaping @Sendable (SSEvent) -> Void,
                onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.config = config
        self.backoff = backoff
        self.tokenProvider = tokenProvider
        self.onEvent = onEvent
        self.onStateChange = onStateChange
    }

    public func start() {
        guard task == nil else { return }
        task = _Concurrency.Task { await run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        setState(.idle)
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange(new)
    }

    private var attempt = 0

    private func run() async {
        while !_Concurrency.Task.isCancelled {
            attempt += 1
            setState(.connecting)
            do {
                try await consumeStream()
            } catch {
                // fall through to reconnect
            }
            if _Concurrency.Task.isCancelled { break }
            setState(.down)
            let delay = backoff.jitteredDelay(forAttempt: attempt)
            try? await _Concurrency.Task.sleep(for: .seconds(delay))
        }
    }

    private func consumeStream() async throws {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("events"))
        request.timeoutInterval = 3600  // long-lived by design
        request.setValue("Bearer \(try tokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        var parser = SSEParser()
        var seenFirst = false

        for try await line in bytes.lines {
            if _Concurrency.Task.isCancelled { return }
            guard let event = parser.consume(line: line) else { continue }
            if !seenFirst {
                // Only count as connected once frames actually arrive — a
                // socket that opens and hangs isn't a working stream.
                seenFirst = true
                attempt = 0
                setState(.connected)
            }
            // `hello` is the greeting; everything else is worth reacting to.
            if event.name != "hello" { onEvent(event) }
        }
        // Stream ended cleanly (server restart etc.) → caller reconnects.
    }
}
