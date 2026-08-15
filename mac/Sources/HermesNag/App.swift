import AppKit
import HermesNagCore
import SwiftUI

/// Menu-bar app with an always-visible desktop widget (LSUIElement=true — no
/// Dock icon, no window in the app switcher).
///
/// The widget is the product: a passive thing you glance at. The escalation
/// ladder from M3/M4 still runs and stays tested, but presents nothing unless
/// `nagsEnabled` is turned on.
final class AppDelegate: NSObject, NSApplicationDelegate {

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }
        DockIcon.applySaved()
        AppStore.shared.start()
        WidgetHost.shared.show()
    }

    /// Clicking the Dock icon (when shown) brings the widget forward — the
    /// whole point of having the icon is a one-click way back to it.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        WidgetHost.shared.show()
        return false
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        AppStore.shared.stop()  // kill the ssh child rather than orphaning it
    }

    /// Refuse to be the second copy.
    ///
    /// Launching the binary directly (rather than via `open`) bypasses macOS's
    /// single-instance handling, and three copies once stacked up unnoticed —
    /// three menu bar icons, three poll loops. Cheap to prevent, annoying to
    /// diagnose.
    @MainActor
    private func terminateIfAlreadyRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = Bundle.main.bundleIdentifier ?? "com.dhana.hermesnag"

        let duplicates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == mine && $0.processIdentifier != me
        }
        guard !duplicates.isEmpty else { return false }

        NSLog("[HermesNag] already running (pid \(duplicates[0].processIdentifier)); exiting")
        NSApp.terminate(nil)
        return true
    }
}

/// Dock-icon visibility. The bundle ships LSUIElement=true (menu-bar app),
/// but the activation policy can be flipped at runtime — some people want a
/// Dock icon as the way back to the widget, some want zero footprint.
@MainActor
enum DockIcon {
    private static let key = "showDockIcon"

    static var isShown: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func set(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: key)
        apply(show)
    }

    static func applySaved() { apply(isShown) }

    private static func apply(_ show: Bool) {
        // .regular = Dock icon + Cmd-Tab; .accessory = menu bar only.
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show {
            // Policy flips only take full effect once the app activates.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Owns the desktop widget window. Separate from AppStore so the store stays
/// free of window management.
@MainActor
final class WidgetHost {
    static let shared = WidgetHost()
    private lazy var controller = DesktopWidgetController(store: AppStore.shared)

    func show() { controller.show() }
    func toggle() { controller.toggle() }
    func resetPosition() { controller.resetPosition() }
    func setFullScreenSuppression(_ s: Bool) { controller.setFullScreenSuppression(s) }
    func setLayer(_ layer: WidgetLayer) { controller.setLayer(layer) }
    var layer: WidgetLayer { controller.layer }
    var isVisible: Bool { controller.isVisible }
}

@main
struct HermesNagApp: App {
    private let store = AppStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPopover(store: store)
                // Started from the view lifecycle, NOT App.init(): @State's
                // initializer is only a template SwiftUI may discard, so
                // start() there can supervise an object the UI never renders.
                // start() is idempotent, so this is a safe backstop.
                .task { store.start() }
        } label: {
            Image(systemName: store.menuBarSymbol)
                .accessibilityLabel("HermesNag — \(store.statusLine)")
        }
        .menuBarExtraStyle(.window)  // .window allows a real SwiftUI popover
    }
}
