import AppKit
import HermesNagCore
import SwiftUI

// L1/L2 floating panel.
//
// L1: non-activating, bottom-right, springs in, auto-dismisses after 30s.
// L2: larger, centred, `.statusBar` level, joins all Spaces, sound, and the
//     snooze button is disabled for 5s so it can't be reflex-dismissed.
//
// `.nonactivatingPanel` matters: the panel must never steal focus from what
// you're typing into. A reminder that interrupts your keystrokes would get
// this app deleted within a day.

/// A panel that can never become key or main.
///
/// This is load-bearing, not cosmetic. A borderless `.nonactivatingPanel` can
/// still accept key status, and then a Return or Space intended for the app
/// you were actually working in gets routed to whichever button SwiftUI made
/// default — silently completing or snoozing a task. Verified in testing:
/// a snooze POST landed 0.0s after the panel appeared, with no user input.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NagPanelController {
    private var panels: [String: NSPanel] = [:]
    private let onAction: (String, NagAction) -> Void

    init(onAction: @escaping (String, NagAction) -> Void) {
        self.onAction = onAction
    }

    var presentedIDs: Set<String> { Set(panels.keys) }

    func present(task: Task, level: EscalationLevel, nagLine: String) {
        // Escalating: tear the old one down first so L1 doesn't linger behind L2.
        if panels[task.id] != nil {
            dismiss(taskID: task.id, animated: false)
        }

        let isL2 = level >= .annoyed
        let size = isL2 ? CGSize(width: 460, height: 240) : CGSize(width: 380, height: 180)

        let panel = NonKeyPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = isL2 ? .statusBar : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow

        // Never take key status. Without this the panel can swallow a Return
        // or Space you meant for whatever you were actually typing in, and
        // silently "click" a button — observed completing and snoozing tasks
        // with no user input at all. Actions must require a real mouse click.
        panel.worksWhenModal = false

        let view = NagPanelView(
            task: task,
            level: level,
            nagLine: nagLine,
            onAction: { [weak self] action in
                self?.onAction(task.id, action)
                self?.dismiss(taskID: task.id)
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        position(panel, isL2: isL2, size: size)
        panels[task.id] = panel

        // orderFrontRegardless: show without activating the app, so focus stays
        // wherever the user was working.
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        if isL2 {
            Theme.shared.playAlert()
        }
    }

    private func position(_ panel: NSPanel, isL2: Bool, size: CGSize) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame

        let origin: CGPoint
        if isL2 {
            // Centred, slightly above middle — harder to ignore.
            origin = CGPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 + 60
            )
        } else {
            origin = CGPoint(
                x: frame.maxX - size.width - 20,
                y: frame.minY + 20
            )
        }
        panel.setFrameOrigin(origin)
    }

    func dismiss(taskID: String, animated: Bool = true) {
        guard let panel = panels.removeValue(forKey: taskID) else { return }
        guard animated else { panel.orderOut(nil); return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    func dismissAll() {
        for id in panels.keys { dismiss(taskID: id, animated: false) }
    }
}

enum NagAction: Equatable {
    case done
    case snooze(minutes: Int)
    case notToday
}

struct NagPanelView: View {
    let task: Task
    let level: EscalationLevel
    let nagLine: String
    let onAction: (NagAction) -> Void

    @State private var appeared = false
    @State private var snoozeUnlocked = false
    /// Buttons ignore clicks until the panel has been up briefly.
    ///
    /// Without this, a panel that springs in under the pointer can receive a
    /// click the user aimed at whatever was underneath — observed completing
    /// a task with `appActive=false` and no deliberate input. A reminder that
    /// dismisses itself from a stray click is worse than useless: it silently
    /// marks work done that was never done.
    @State private var acceptsInput = false
    private static let inputGraceperiod: Duration = .milliseconds(400)

    private var isL2: Bool { level >= .annoyed }
    private var mood: MascotMood { MascotMood.forLevel(level) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: mood.symbol)
                    .font(isL2 ? .largeTitle : .title)
                    .foregroundStyle(isL2 ? .orange : .accentColor)
                    .symbolEffect(.bounce, value: appeared)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(isL2 ? .title3.weight(.semibold) : .headline)
                        .lineLimit(2)

                    if let due = task.dueAt {
                        Text(TodayPlanner.relativeLabel(for: due, now: Date()))
                            .font(.caption)
                            .foregroundStyle(isL2 ? .red : .secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(nagLine)
                .font(isL2 ? .body : .callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    guard acceptsInput else { return }
                    onAction(.done)
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(isL2 ? .large : .regular)
                // No .keyboardShortcut(.defaultAction): making this the default
                // button let a stray Return complete a task without a click.

                Button("Snooze 10m") {
                    guard acceptsInput else { return }
                    onAction(.snooze(minutes: 10))
                }
                    .controlSize(isL2 ? .large : .regular)
                    // Spec: at L2 the snooze button is disabled for 5s, so
                    // dismissal is deliberate rather than reflex.
                    .disabled(isL2 && !snoozeUnlocked)

                Button("Not today") {
                    guard acceptsInput else { return }
                    onAction(.notToday)
                }
                    .controlSize(isL2 ? .large : .regular)
            }
        }
        .padding(isL2 ? 22 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isL2 ? Color.orange.opacity(0.5) : Color.primary.opacity(0.1),
                              lineWidth: isL2 ? 2 : 1)
        )
        .scaleEffect(appeared ? 1 : 0.92)
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: appeared)
        .task {
            appeared = true
            // Swallow clicks that were already in flight toward whatever the
            // panel just covered.
            try? await _Concurrency.Task.sleep(for: Self.inputGraceperiod)
            acceptsInput = true
            guard isL2 else { snoozeUnlocked = true; return }
            try? await _Concurrency.Task.sleep(for: .seconds(Escalation.annoyedSnoozeCooldown))
            snoozeUnlocked = true
        }
    }
}
