import Foundation

/// Tunnel state and reconnect policy — pure logic, no Process, no timers.
///
/// Separating the *policy* from the *process supervision* is what makes this
/// testable: the backoff schedule and state transitions are verified in
/// milliseconds without ever spawning ssh or waiting on a real clock.

public enum TunnelState: Equatable, Sendable {
    case idle
    case connecting(attempt: Int)
    case up
    case down(reason: String)

    /// Menu bar dot colour. The spec asks for green/amber/red.
    public var indicator: Indicator {
        switch self {
        case .up: return .green
        case .connecting: return .amber
        case .down: return .red
        case .idle: return .grey
        }
    }

    public var isUp: Bool { self == .up }

    /// Shown in the popover. The spec insists auth failures surface an
    /// actionable message rather than a silent red dot.
    public var describedForUser: String {
        switch self {
        case .idle: return "Not started"
        case .connecting(let n): return n <= 1 ? "Connecting…" : "Reconnecting (attempt \(n))…"
        case .up: return "Connected"
        case .down(let reason): return reason
        }
    }
}

public enum Indicator: String, Sendable {
    case green, amber, red, grey
}

/// Exponential backoff with jitter: 1s → 60s cap, per the spec.
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval
    public let jitterFraction: Double

    public init(base: TimeInterval = 1.0, cap: TimeInterval = 60.0, jitterFraction: Double = 0.2) {
        self.base = base
        self.cap = cap
        self.jitterFraction = jitterFraction
    }

    /// Delay before `attempt` (1-based), ignoring jitter.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = Double(attempt - 1)
        let raw = base * pow(2.0, exponent)
        return min(raw, cap)
    }

    /// Delay with jitter applied. `random` is injectable so tests are
    /// deterministic — jitter is exactly the kind of thing that makes a
    /// flaky test suite if you let it call a real RNG.
    public func jitteredDelay(forAttempt attempt: Int,
                              random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> TimeInterval {
        let d = delay(forAttempt: attempt)
        guard d > 0, jitterFraction > 0 else { return d }
        let spread = d * jitterFraction
        return max(0, d + random(-spread...spread))
    }
}

/// Classifies why ssh exited, so the UI can say something useful.
public enum TunnelFailure: Equatable, Sendable {
    case authenticationFailed
    case hostUnreachable
    case portInUse
    case forwardingFailed
    case unknown(String)

    public var userMessage: String {
        switch self {
        case .authenticationFailed:
            return "SSH auth failed — check your key is in the agent (ssh-add -l)"
        case .hostUnreachable:
            return "Can't reach the server — check your connection"
        case .portInUse:
            return "Port 8787 already in use locally"
        case .forwardingFailed:
            return "Port forwarding was refused by the server"
        case .unknown(let detail):
            return detail.isEmpty ? "Tunnel disconnected" : detail
        }
    }

    /// Retrying an auth failure just burns cycles until the user fixes the key.
    public var isRetryable: Bool {
        self != .authenticationFailed
    }

    /// Map ssh's stderr to a cause. Ordering matters: "address already in use"
    /// also mentions forwarding, so the more specific check runs first.
    public static func classify(stderr: String, exitCode: Int32) -> TunnelFailure {
        let s = stderr.lowercased()

        if s.contains("permission denied") || s.contains("publickey")
            || s.contains("authentication failed") {
            return .authenticationFailed
        }
        if s.contains("address already in use") || s.contains("cannot listen to port") {
            return .portInUse
        }
        if s.contains("could not resolve hostname") || s.contains("no route to host")
            || s.contains("connection timed out") || s.contains("network is unreachable")
            || s.contains("connection refused") {
            return .hostUnreachable
        }
        if s.contains("remote port forwarding failed") || s.contains("channel setup failed") {
            return .forwardingFailed
        }

        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .unknown("Tunnel exited (code \(exitCode))")
        }
        return .unknown(String(trimmed.prefix(200)))
    }
}

/// The supervised ssh invocation. The host alias comes from user settings.
public struct TunnelConfig: Sendable {
    public var sshPath: String
    public var host: String
    public var localPort: Int
    public var remotePort: Int

    /// The ~/.ssh/config alias for the server box. Set once in Settings
    /// (persisted as `sshHost`); credentials stay in ssh config + agent.
    public static var configuredHost: String {
        get { UserDefaults.standard.string(forKey: "sshHost") ?? "hermesnag-server" }
        set { UserDefaults.standard.set(newValue, forKey: "sshHost") }
    }

    public init(sshPath: String = "/usr/bin/ssh",
                host: String = TunnelConfig.configuredHost,
                localPort: Int = 8787,
                remotePort: Int = 8787) {
        self.sshPath = sshPath
        self.host = host
        self.localPort = localPort
        self.remotePort = remotePort
    }

    public var arguments: [String] {
        [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
            host,
        ]
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(localPort)")!
    }
}
