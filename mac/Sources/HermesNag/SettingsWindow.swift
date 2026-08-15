import AppKit
import CoreImage.CIFilterBuiltins
import HermesNagCore
import SwiftUI

/// A real Settings window. User-facing settings live here; the ladybug menu
/// keeps only debug/simulator tools.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "HermesNag Settings"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SettingsView(store: AppStore.shared))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}

struct SettingsView: View {
    @Bindable var store: AppStore
    @Bindable var theme = Theme.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme.appearance) {
                    ForEach(Theme.Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Colour tone", selection: $theme.accent) {
                    ForEach(Theme.Accent.allCases, id: \.self) { accent in
                        Label(accent.label, systemImage: "circle.fill")
                            .foregroundStyle(accent.color)
                            .tag(accent)
                    }
                }

                Picker("Text size", selection: $theme.textSize) {
                    ForEach(Theme.TextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Background", selection: $theme.background) {
                    ForEach(Theme.Background.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Opacity") {
                    Slider(value: $theme.backgroundOpacity, in: 0.6...1.0)
                }
                LabeledContent("Corner radius") {
                    Slider(value: $theme.cornerRadius, in: 10...20)
                }

                preview
            }

            Section("Sounds") {
                Picker("Nudge sound", selection: $theme.nudgeSound) {
                    ForEach(Theme.soundChoices, id: \.self) { choice in
                        Text(Theme.soundLabel(choice)).tag(choice)
                    }
                }
                Button {
                    Theme.shared.playAlert()
                } label: {
                    Label("Preview", systemImage: "play.circle")
                }
                .disabled(theme.nudgeSound == "none")
            }

            Section("Phone") {
                if let qr = phoneQR {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(nsImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 150, height: 150)
                            Text("Scan with the iPhone camera (Tailscale on).\nToken travels in the URL fragment — never sent to the server.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Spacer()
                    }
                } else {
                    Text("Set your tailnet URL below (and have a token in the Keychain) to get a phone QR.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("Phone base URL (e.g. https://your-box.your-tailnet.ts.net:10003)",
                          text: phoneURLBinding)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Behaviour") {
                Picker("Widget layering", selection: layerBinding) {
                    ForEach(WidgetLayer.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Show Dock icon", isOn: dockBinding)
                Toggle("Start at login", isOn: $store.startsAtLogin)
                Toggle("Popup nagging (L1–L3 ladder)", isOn: $store.nagsEnabled)
                TextField("SSH host alias (~/.ssh/config)", text: sshHostBinding)
                    .textFieldStyle(.roundedBorder)
                    .help("Takes effect on next launch")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 560)
    }

    /// Live preview — a fake task and habit rendered with the current theme,
    /// so changes are visible without hunting for the widget.
    private var preview: some View {
        let theme = Theme.shared
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.system(size: theme.fs(13)))
                    .foregroundStyle(.secondary)
                Text("Sample task")
                    .font(.system(size: theme.fs(12)))
                Spacer()
                Text("18:00")
                    .font(.system(size: theme.fs(10), design: .rounded))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "drop")
                    .font(.system(size: theme.fs(12)))
                    .foregroundStyle(theme.accentColor)
                Text("Drink water")
                    .font(.system(size: theme.fs(11)))
                Spacer()
                Text("now")
                    .font(.system(size: theme.fs(10), design: .rounded))
                    .foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.accentColor.opacity(0.12)))
        }
        .padding(10)
        .background {
            Theme.shared.backgroundView
                .clipShape(RoundedRectangle(cornerRadius: Theme.shared.cornerRadius))
        }
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .preferredColorScheme(theme.scheme)
    }

    private var layerBinding: Binding<WidgetLayer> {
        Binding(get: { WidgetHost.shared.layer },
                set: { WidgetHost.shared.setLayer($0) })
    }

    private var dockBinding: Binding<Bool> {
        Binding(get: { DockIcon.isShown }, set: { DockIcon.set($0) })
    }

    private var phoneURLBinding: Binding<String> {
        Binding(get: { UserDefaults.standard.string(forKey: "phoneBaseURL") ?? "" },
                set: { UserDefaults.standard.set($0, forKey: "phoneBaseURL") })
    }

    private var sshHostBinding: Binding<String> {
        Binding(get: { TunnelConfig.configuredHost },
                set: { TunnelConfig.configuredHost = $0 })
    }

    /// One scan replaces ssh + grep + paste. The token rides the URL
    /// *fragment*, which browsers never transmit — the page reads it locally,
    /// stores it, and strips it from the address bar.
    private var phoneQR: NSImage? {
        guard let token = try? Keychain.readToken() else { return nil }
        guard let base = UserDefaults.standard.string(forKey: "phoneBaseURL"),
              !base.isEmpty else { return nil }
        let url = "\(base)/m#t=\(token)"

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
