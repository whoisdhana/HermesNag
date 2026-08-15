import Testing
import Foundation
@testable import HermesNagCore

/// Backoff and failure classification. No processes spawned, no sleeping —
/// the policy is pure, so this runs in microseconds (spec Rule 3).
@Suite struct TunnelStateTests {

    // MARK: - Backoff

    @Test func testBackoffStartsAtOneSecond() {
        #expect(Backoff().delay(forAttempt: 1) == 1.0)
    }

    @Test func testBackoffDoublesEachAttempt() {
        let b = Backoff()
        #expect(b.delay(forAttempt: 2) == 2.0)
        #expect(b.delay(forAttempt: 3) == 4.0)
        #expect(b.delay(forAttempt: 4) == 8.0)
        #expect(b.delay(forAttempt: 5) == 16.0)
    }

    @Test func testBackoffCapsAtSixtySeconds() {
        let b = Backoff()
        #expect(b.delay(forAttempt: 10) == 60.0)
        #expect(b.delay(forAttempt: 99) == 60.0, "must never exceed the cap")
    }

    @Test func testJitterStaysWithinBounds() {
        let b = Backoff(base: 1, cap: 60, jitterFraction: 0.2)
        // Deterministic extremes instead of a real RNG.
        let low = b.jitteredDelay(forAttempt: 3, random: { $0.lowerBound })
        let high = b.jitteredDelay(forAttempt: 3, random: { $0.upperBound })
        #expect(abs((low) - (4.0 - 0.8)) < 0.0001)
        #expect(abs((high) - (4.0 + 0.8)) < 0.0001)
    }

    @Test func testJitterNeverGoesNegative() {
        let b = Backoff(base: 1, cap: 60, jitterFraction: 2.0)  // absurd jitter
        #expect(b.jitteredDelay(forAttempt: 1, random: { $0.lowerBound }) >= 0)
    }

    // MARK: - Indicator

    @Test func testIndicatorColours() {
        #expect(TunnelState.up.indicator == .green)
        #expect(TunnelState.connecting(attempt: 1).indicator == .amber)
        #expect(TunnelState.down(reason: "x").indicator == .red)
        #expect(TunnelState.idle.indicator == .grey)
    }

    @Test func testReconnectMessageShowsAttemptNumber() {
        #expect(TunnelState.connecting(attempt: 1).describedForUser == "Connecting…")
        #expect(TunnelState.connecting(attempt: 4).describedForUser.contains("4"))
    }

    // MARK: - Failure classification

    @Test func testAuthFailureIsRecognised() {
        let f = TunnelFailure.classify(stderr: "Permission denied (publickey).", exitCode: 255)
        #expect(f == .authenticationFailed)
    }

    @Test func testAuthFailureIsNotRetried() {
        // Retrying forever would spam the server while the key stays broken.
        #expect(!(TunnelFailure.authenticationFailed.isRetryable))
        #expect(TunnelFailure.hostUnreachable.isRetryable)
    }

    @Test func testAuthFailureMessageIsActionable() {
        // Spec: surface a clear actionable error, not a silent red dot.
        let msg = TunnelFailure.authenticationFailed.userMessage
        #expect(msg.lowercased().contains("ssh-add") || msg.lowercased().contains("key"))
    }

    @Test func testUnreachableHostIsRecognised() {
        #expect(TunnelFailure.classify(
            stderr: "ssh: Could not resolve hostname foo", exitCode: 255) == .hostUnreachable)
        #expect(TunnelFailure.classify(
            stderr: "connect: Network is unreachable", exitCode: 255) == .hostUnreachable)
    }

    @Test func testPortInUseIsRecognised() {
        let f = TunnelFailure.classify(
            stderr: "bind [127.0.0.1]:8787: Address already in use", exitCode: 255)
        #expect(f == .portInUse)
    }

    @Test func testPortInUseWinsOverForwardingMessage() {
        // ssh prints both lines; the specific cause must win.
        let stderr = """
        bind [127.0.0.1]:8787: Address already in use
        channel_setup_fwd_listener_tcpip: cannot listen to port: 8787
        """
        #expect(TunnelFailure.classify(stderr: stderr, exitCode: 255) == .portInUse)
    }

    @Test func testEmptyStderrStillProducesAMessage() {
        let f = TunnelFailure.classify(stderr: "", exitCode: 1)
        guard case .unknown(let msg) = f else {
            Issue.record("expected .unknown, got \(f)")
            return
        }
        #expect(msg.contains("1"))
    }

    // MARK: - Config

    @Test func testTunnelArgumentsMatchTheSpec() {
        let args = TunnelConfig().arguments
        #expect(args.contains("-N"))
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("ServerAliveInterval=15"))
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("127.0.0.1:8787:127.0.0.1:8787"))
    }

    @Test func testHostComesFromUserSettings() {
        // The alias is configuration, not a constant — set in Settings,
        // persisted as `sshHost`, with a neutral fallback.
        UserDefaults.standard.removeObject(forKey: "sshHost")
        #expect(TunnelConfig().host == "hermesnag-server")

        TunnelConfig.configuredHost = "my-box"
        #expect(TunnelConfig().host == "my-box")
        #expect(TunnelConfig().arguments.contains("my-box"))
        UserDefaults.standard.removeObject(forKey: "sshHost")
    }

    @Test func testBaseURLIsLoopbackOnly() {
        #expect(TunnelConfig().baseURL.absoluteString == "http://127.0.0.1:8787")
    }
}
