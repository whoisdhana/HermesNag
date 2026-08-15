import Foundation
import HermesNagCore
import Observation

/// Spawns and supervises `ssh -N -L`, republishing its state for the UI.
///
/// Credentials are never bundled — this relies on ~/.ssh/config and the agent
/// (spec). BatchMode=yes means ssh fails fast instead of hanging on a prompt,
/// which is what lets us classify auth failures and tell the user something
/// useful instead of showing a silent red dot.
@Observable
@MainActor
public final class TunnelManager {
    public private(set) var state: TunnelState = .idle
    public private(set) var lastConnectedAt: Date?

    private let config: TunnelConfig
    private let backoff: Backoff
    private var process: Process?
    private var supervisorTask: _Concurrency.Task<Void, Never>?
    private var attempt = 0
    private var stopping = false

    public init(config: TunnelConfig = TunnelConfig(),
                backoff: Backoff = Backoff()) {
        self.config = config
        self.backoff = backoff
    }

    public var baseURL: URL { config.baseURL }

    public func start() {
        guard supervisorTask == nil else { return }
        stopping = false
        supervisorTask = _Concurrency.Task { [weak self] in
            await self?.supervise()
        }
    }

    public func stop() {
        stopping = true
        supervisorTask?.cancel()
        supervisorTask = nil
        terminateProcess()
        state = .idle
    }

    /// Skip the remaining backoff and retry now — the popover's "Retry" button.
    public func retryNow() {
        guard !stopping else { return }
        attempt = 0
        terminateProcess()  // the supervisor loop notices and reconnects
    }

    private func terminateProcess() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    private func supervise() async {
        while !_Concurrency.Task.isCancelled && !stopping {
            attempt += 1
            state = .connecting(attempt: attempt)

            let failure = await runOnce()

            if _Concurrency.Task.isCancelled || stopping { break }

            if let failure {
                state = .down(reason: failure.userMessage)

                // Auth failures repeat forever until the user acts; retrying
                // every second just spams the log and the server.
                if !failure.isRetryable {
                    break
                }
            } else {
                state = .down(reason: "Tunnel closed")
            }

            let delay = backoff.jitteredDelay(forAttempt: attempt)
            try? await _Concurrency.Task.sleep(for: .seconds(delay))
        }
    }

    /// Runs ssh until it exits. Returns the classified failure, or nil for a
    /// clean exit.
    private func runOnce() async -> TunnelFailure? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.sshPath)
        proc.arguments = config.arguments

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
        } catch {
            return .unknown("Could not launch ssh: \(error.localizedDescription)")
        }

        process = proc

        // ssh -N stays silent while healthy. Give the forward a moment to bind,
        // then treat a still-running process as connected.
        try? await _Concurrency.Task.sleep(for: .milliseconds(700))
        if proc.isRunning && !stopping {
            attempt = 0          // a successful connection resets the backoff
            state = .up
            lastConnectedAt = Date()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in continuation.resume() }
        }

        process = nil

        if stopping || _Concurrency.Task.isCancelled { return nil }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        // SIGTERM from retryNow()/stop() is us, not a real failure.
        if proc.terminationReason == .uncaughtSignal && stderr.isEmpty {
            return nil
        }

        return TunnelFailure.classify(stderr: stderr, exitCode: proc.terminationStatus)
    }

    // No deinit cancellation: supervisorTask is main-actor isolated and deinit
    // is nonisolated. stop() is the explicit teardown path, called by AppStore.
}
