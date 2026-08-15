import AppKit
import HermesNagCore
import SwiftUI

/// L3 — full-screen takeover on every display.
///
/// The most intrusive thing this app does, so two rules govern it:
///   * **Done is one click.** Dealing with the task is always the easy path.
///   * **Escape is high friction, but never impossible** — hold for 3 seconds,
///     or type the task title. The spec is explicit that it must never trap you.
@MainActor
final class TakeoverWindowController {
    private var windows: [NSWindow] = []
    private let onAction: (String, TakeoverResult) -> Void

    init(onAction: @escaping (String, TakeoverResult) -> Void) {
        self.onAction = onAction
    }

    var isShowing: Bool { !windows.isEmpty }
    var windowCount: Int { windows.count }

    func present(task: Task, nagLine: String) {
        dismiss()

        // One window per screen — the spec says every display, so a second
        // monitor can't be used as an escape hatch.
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )

            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.animationBehavior = .none

            let view = TakeoverView(
                task: task,
                nagLine: nagLine,
                onResult: { [weak self] result in
                    self?.onAction(task.id, result)
                    self?.dismiss()
                }
            )
            window.contentView = NSHostingView(rootView: view)
            window.setFrame(screen.frame, display: true)

            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                window.animator().alphaValue = 1
            }

            windows.append(window)
        }

        Theme.shared.playAlert()
    }

    func dismiss() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }
}

enum TakeoverResult: Equatable {
    case done
    case escaped        // held the button or typed the title
}

struct TakeoverView: View {
    let task: Task
    let nagLine: String
    let onResult: (TakeoverResult) -> Void

    @State private var appeared = false
    @State private var holdProgress: Double = 0
    @State private var holdTask: _Concurrency.Task<Void, Never>?
    @State private var typedTitle = ""
    @State private var showTypeEscape = false
    /// Same 400ms guard as NagPanel: a window that covers the whole screen
    /// could otherwise swallow an in-flight click and mark work done that
    /// was never done. Verified as a real failure mode in M3.
    @State private var acceptsInput = false

    private static let holdDuration: TimeInterval = 3.0

    private var titleMatches: Bool {
        typedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(task.title) == .orderedSame
    }

    var body: some View {
        ZStack {
            // Blurred backdrop — you can see your work, but not use it.
            VisualEffectBackdrop()
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: MascotMood.glaring.symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating, value: appeared)

                VStack(spacing: 12) {
                    Text(task.title)
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)

                    Text(nagLine)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 60)

                if let due = task.dueAt {
                    Label(TodayPlanner.relativeLabel(for: due, now: Date()),
                          systemImage: "clock.badge.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(.red)
                }

                // Done — one click, always the easiest path out.
                Button {
                    guard acceptsInput else { return }
                    onResult(.done)
                } label: {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.title2)
                        .frame(width: 260, height: 56)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)

                escapeControls
            }
            .padding(60)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: appeared)
        }
        .task {
            appeared = true
            try? await _Concurrency.Task.sleep(for: .milliseconds(400))
            acceptsInput = true
        }
    }

    private var escapeControls: some View {
        VStack(spacing: 14) {
            // Press-and-hold for 3s. Deliberately tedious, never impossible.
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 260, height: 40)

                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.orange.opacity(0.5))
                        .frame(width: geo.size.width * holdProgress)
                }
                .frame(width: 260, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(holdProgress > 0 ? "Keep holding…" : "Hold 3s to escape")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: .infinity) {
                guard acceptsInput else { return }
                onResult(.escaped)
            } onPressingChanged: { pressing in
                guard acceptsInput else { return }
                holdTask?.cancel()
                if pressing {
                    holdTask = _Concurrency.Task {
                        let steps = 60
                        for step in 0...steps {
                            if _Concurrency.Task.isCancelled { return }
                            holdProgress = Double(step) / Double(steps)
                            try? await _Concurrency.Task.sleep(
                                for: .seconds(Self.holdDuration / Double(steps)))
                        }
                    }
                } else {
                    holdProgress = 0
                }
            }

            Button("or type the task title to dismiss") {
                showTypeEscape.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)

            if showTypeEscape {
                HStack {
                    TextField("Type: \(task.title)", text: $typedTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                        .onSubmit {
                            if titleMatches { onResult(.escaped) }
                        }
                    Button("Dismiss") { onResult(.escaped) }
                        .disabled(!titleMatches)
                }
            }
        }
    }
}

/// Blurred backdrop. NSVisualEffectView has no direct SwiftUI equivalent that
/// blurs the desktop behind a borderless window.
struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
