import AppKit
import CoreGraphics
import HermesNagCore

/// Reads real system conditions into the engine's `UserState`.
///
/// This is the load-bearing half of M4. The safety valves existed in
/// `ReminderEngine` since M3 and were covered by passing tests, but **nothing
/// ever set them** — `screenLocked`, `isPresenting` and `takeoverDisabled` sat
/// at their defaults forever. Tested guards that are never fed real data are
/// decorative, and shipping a full-screen takeover on top of decorative guards
/// is how this app ends up seizing the screen during a client call.
@MainActor
enum SystemState {

    /// Apps that mean "don't take over the screen right now".
    /// Overridable via `defaults write com.dhana.hermesnag presenterApps -array ...`
    /// so a new video app doesn't need a rebuild.
    static let defaultPresenters: Set<String> = [
        "zoom.us", "Zoom", "Google Meet", "Microsoft Teams", "Teams",
        "Keynote", "QuickTime Player", "OBS Studio", "OBS",
        "Screenflick", "ScreenFlow", "Loom", "Webex", "Slack",  // Slack huddles
    ]

    static var presenterApps: Set<String> {
        if let custom = UserDefaults.standard.array(forKey: "presenterApps") as? [String],
           !custom.isEmpty {
            return Set(custom)
        }
        return defaultPresenters
    }

    /// Spec valve 6: never fire while the screen is locked — queue for unlock.
    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // Absent key means unlocked; only an explicit 1 counts as locked.
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// Spec valve 1: never L3 during screen capture or a presentation.
    ///
    /// Checks the frontmost app *and* every on-screen window owner: Zoom can be
    /// sharing your screen while Chrome is frontmost, and that's exactly the
    /// moment a takeover would be most embarrassing.
    static var isPresenting: Bool {
        let presenters = presenterApps

        if let front = NSWorkspace.shared.frontmostApplication?.localizedName,
           presenters.contains(front) {
            return true
        }

        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  presenters.contains(owner) else { continue }
            // Ignore tiny helper windows (menu bar items, notifications) —
            // only a real window suggests an actual call or recording.
            if let bounds = window[kCGWindowBounds as String] as? [String: Any],
               let height = bounds["Height"] as? Double, height > 200 {
                return true
            }
        }
        return false
    }

    /// Spec valve 4: `defaults write com.dhana.hermesnag disableTakeover -bool YES`
    /// must work without a rebuild — so this is read every tick, never cached.
    static var takeoverDisabled: Bool {
        UserDefaults.standard.bool(forKey: "disableTakeover")
    }

    /// Is another app showing a full-screen window (its own Space)?
    ///
    /// The widget has `.canJoinAllSpaces` so it follows you between desktops —
    /// but that also dragged it on top of full-screen YouTube. Heuristic: a
    /// layer-0 window sized exactly to a screen is a full-screen Space;
    /// merely-maximized windows sit below the menu bar so their height
    /// differs. Our own windows and the takeover are excluded.
    static var anotherAppIsFullScreen: Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let screenSizes = NSScreen.screens.map { $0.frame.size }
        let myPID = ProcessInfo.processInfo.processIdentifier

        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int32) != myPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double,
                  let h = bounds["Height"] as? Double else { continue }
            if screenSizes.contains(where: { abs($0.width - w) < 2 && abs($0.height - h) < 2 }) {
                return true
            }
        }
        return false
    }

    /// Snapshot of everything the engine's valves need, taken fresh each tick.
    static func current() -> (screenLocked: Bool, isPresenting: Bool, takeoverDisabled: Bool) {
        (isScreenLocked, isPresenting, takeoverDisabled)
    }
}
