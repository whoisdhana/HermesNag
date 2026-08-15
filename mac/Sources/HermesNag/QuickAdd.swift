import AppKit
import HermesNagCore
import SwiftUI

/// ⌃⌥Space — Spotlight-style capture from anywhere.
///
/// The whole point is zero context switch: hit the key mid-email, type
/// "call the school tomorrow 3pm", Return, keep working. Same parser as
/// every other add box, so `habit:`, times, #tags and "urgent" all work.
@MainActor
final class QuickAddController {
    static let shared = QuickAddController()
    private var panel: NSPanel?

    func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    func open() {
        if panel == nil { build() }
        guard let panel else { return }

        // Centre on the screen the mouse is on — that's where attention is.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.midY + visible.height * 0.18))
        }

        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func build() {
        let p = WidgetPanel(   // canBecomeKey=true, never becomes main
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: QuickAddView(
            onSubmit: { [weak self] text in
                AppStore.shared.addFromWidget(raw: text)
                self?.close()
            },
            onCancel: { [weak self] in self?.close() }
        ))
        panel = p
    }
}

struct QuickAddView: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    var theme: Theme { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.accentColor)

                TextField("Nag me about…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .light))
                    .focused($focused)
                    .onSubmit(submit)
            }

            Text("e.g. \"pay bill friday 6pm #home urgent\"  ·  \"habit: meditate daily\"  ·  esc to close")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(theme.accentColor.opacity(0.35), lineWidth: 1))
        .onExitCommand(perform: onCancel)
        .onAppear {
            text = ""
            focused = true
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onCancel(); return }
        text = ""
        onSubmit(trimmed)
    }
}
