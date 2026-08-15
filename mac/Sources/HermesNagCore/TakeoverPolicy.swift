import Foundation

/// Rate limiting and downgrade accounting for L3 takeover.
///
/// Pure and injectable, like the rest of the engine. The takeover is the most
/// intrusive thing this app does, so every refusal to fire one is an explicit,
/// named decision that gets recorded — the spec says "downgrade to L2 instead
/// and log why", and a silent downgrade would be indistinguishable from a bug.

/// Why a takeover was refused. Never `nil` when a downgrade happens.
public enum TakeoverSuppression: String, Sendable, Equatable, CaseIterable {
    case presenting        // screen-sharing / a presenter app is frontmost
    case killSwitch        // defaults write com.dhana.hermesnag disableTakeover -bool YES
    case cooldown          // one L3 per 45 minutes
    case dailyLimit        // max N per day
    case screenLocked      // queued for unlock instead

    public var userMessage: String {
        switch self {
        case .presenting: return "Held back — you're presenting or sharing your screen"
        case .killSwitch: return "Takeover disabled (disableTakeover is set)"
        case .cooldown: return "Held back — another takeover fired recently"
        case .dailyLimit: return "Held back — daily takeover limit reached"
        case .screenLocked: return "Queued — screen is locked"
        }
    }
}

/// Records of takeovers actually shown, used to enforce the limits.
public struct TakeoverLedger: Codable, Sendable, Equatable {
    public var firedAt: [Date]

    public init(firedAt: [Date] = []) {
        self.firedAt = firedAt
    }

    public mutating func record(_ date: Date) {
        firedAt.append(date)
        // Keep this bounded; nothing older than a day can affect either limit.
        firedAt = firedAt.filter { date.timeIntervalSince($0) < 48 * 3600 }
    }

    public func mostRecent(before now: Date) -> Date? {
        firedAt.filter { $0 <= now }.max()
    }

    /// Count for the *user's* day (Asia/Kolkata), not UTC — "3 per day" has to
    /// mean the user's day or the limit resets at 5:30am local.
    public func countToday(now: Date, calendar: Calendar = .hermesNag) -> Int {
        firedAt.filter { calendar.isDate($0, inSameDayAs: now) }.count
    }
}

public struct TakeoverPolicy: Sendable {
    /// Spec: max one L3 per 45 minutes.
    public let cooldown: TimeInterval
    /// Spec: max N per day, configurable, default 3.
    public let maxPerDay: Int
    public let calendar: Calendar

    public init(cooldown: TimeInterval = 45 * 60,
                maxPerDay: Int = 3,
                calendar: Calendar = .hermesNag) {
        self.cooldown = cooldown
        self.maxPerDay = maxPerDay
        self.calendar = calendar
    }

    /// Read the limits from UserDefaults so they're tunable without a rebuild,
    /// matching how the kill switch works.
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> TakeoverPolicy {
        let cooldown = defaults.object(forKey: "takeoverCooldownSeconds") as? Double
        let perDay = defaults.object(forKey: "takeoverMaxPerDay") as? Int
        return TakeoverPolicy(cooldown: cooldown ?? 45 * 60,
                              maxPerDay: perDay ?? 3)
    }

    /// May a takeover fire right now? Returns the reason if not.
    ///
    /// Order matters: the most *informative* reason wins. Being told "you're
    /// presenting" is more useful than "cooldown" when both are true.
    public func suppression(now: Date,
                            ledger: TakeoverLedger,
                            isPresenting: Bool,
                            killSwitch: Bool,
                            screenLocked: Bool) -> TakeoverSuppression? {
        if screenLocked { return .screenLocked }
        if killSwitch { return .killSwitch }
        if isPresenting { return .presenting }

        if let last = ledger.mostRecent(before: now),
           now.timeIntervalSince(last) < cooldown {
            return .cooldown
        }

        if ledger.countToday(now: now, calendar: calendar) >= maxPerDay {
            return .dailyLimit
        }

        return nil
    }

    /// Seconds until the cooldown expires, for the debug menu's budget display.
    public func cooldownRemaining(now: Date, ledger: TakeoverLedger) -> TimeInterval {
        guard let last = ledger.mostRecent(before: now) else { return 0 }
        return max(0, cooldown - now.timeIntervalSince(last))
    }

    public func remainingToday(now: Date, ledger: TakeoverLedger) -> Int {
        max(0, maxPerDay - ledger.countToday(now: now, calendar: calendar))
    }
}
