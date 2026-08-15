import AppKit
import SwiftUI

/// The widget's look and sounds — one observable model, every property
/// persisted to UserDefaults, consumed live by the widget (it re-renders as
/// you drag the sliders in Settings).
@Observable
@MainActor
final class Theme {
    static let shared = Theme()

    // MARK: - Appearance

    enum Appearance: String, CaseIterable {
        case system, light, dark
        var label: String { rawValue.capitalized }
        var scheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum Accent: String, CaseIterable {
        case orange, blue, green, pink, mono
        var label: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .orange: return .orange
            case .blue: return .blue
            case .green: return .green
            case .pink: return .pink
            case .mono: return .secondary
            }
        }
    }

    enum TextSize: String, CaseIterable {
        case small, medium, large
        var label: String { rawValue.capitalized }
        var factor: CGFloat {
            switch self {
            case .small: return 1.0     // old "medium" — was reported too small
            case .medium: return 1.2
            case .large: return 1.4
            }
        }
    }

    enum Background: String, CaseIterable {
        case frosted, darkSolid, lightSolid
        var label: String {
            switch self {
            case .frosted: return "Frosted glass"
            case .darkSolid: return "Dark"
            case .lightSolid: return "Light"
            }
        }
    }

    var appearance: Appearance {
        didSet { save(appearance.rawValue, "themeAppearance") }
    }
    var accent: Accent {
        didSet { save(accent.rawValue, "themeAccent") }
    }
    var textSize: TextSize {
        didSet { save(textSize.rawValue, "themeTextSize") }
    }
    var background: Background {
        didSet { save(background.rawValue, "themeBackground") }
    }
    var backgroundOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: "themeOpacity") }
    }
    var cornerRadius: Double {
        didSet { UserDefaults.standard.set(cornerRadius, forKey: "themeCornerRadius") }
    }

    // MARK: - Sound

    /// "" = macOS default notification sound; "none" = silent;
    /// anything else = a name from /System/Library/Sounds.
    var nudgeSound: String {
        didSet { save(nudgeSound, "nudgeSound") }
    }

    static let soundChoices = ["", "none", "Glass", "Ping", "Purr", "Submarine", "Tink", "Funk", "Pop", "Hero"]

    static func soundLabel(_ value: String) -> String {
        switch value {
        case "": return "System default"
        case "none": return "None"
        default: return value
        }
    }

    /// Whether UNNotification should carry its own (default) sound. Custom
    /// sounds are played by the app, because UNNotificationSound can't
    /// reference /System/Library/Sounds.
    var notificationCarriesSound: Bool { nudgeSound.isEmpty }

    /// Play the configured alert sound (panels, custom nudges, preview).
    func playAlert() {
        switch nudgeSound {
        case "none": return
        case "": NSSound(named: "Funk")?.play()   // preview stand-in for "default"
        default: NSSound(named: NSSound.Name(nudgeSound))?.play()
        }
    }

    // MARK: - Derived for views

    var fontScale: CGFloat { textSize.factor }
    /// Scaled font size — the widget's `.system(size:)` calls route through this.
    func fs(_ base: CGFloat) -> CGFloat { (base * fontScale).rounded() }
    var scheme: ColorScheme? { appearance.scheme }
    var accentColor: Color { accent.color }

    @ViewBuilder
    var backgroundView: some View {
        switch background {
        case .frosted:
            Rectangle().fill(.ultraThinMaterial).opacity(backgroundOpacity)
        case .darkSolid:
            Color.black.opacity(0.82 * backgroundOpacity)
        case .lightSolid:
            Color.white.opacity(0.88 * backgroundOpacity)
        }
    }

    // MARK: - Persistence

    private func save(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: "themeAppearance") ?? "") ?? .system
        accent = Accent(rawValue: d.string(forKey: "themeAccent") ?? "") ?? .orange
        textSize = TextSize(rawValue: d.string(forKey: "themeTextSize") ?? "") ?? .medium
        background = Background(rawValue: d.string(forKey: "themeBackground") ?? "") ?? .frosted
        backgroundOpacity = d.object(forKey: "themeOpacity") as? Double ?? 1.0
        cornerRadius = d.object(forKey: "themeCornerRadius") as? Double ?? 14
        nudgeSound = d.string(forKey: "nudgeSound") ?? ""
    }
}
