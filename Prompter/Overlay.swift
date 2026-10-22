import AppKit
import Combine
import SwiftUI

/// A small floating panel at the bottom of the screen. Non-activating, so the app you're typing in keeps focus.
@MainActor
final class OverlayController {
    private let panel: NSPanel
    private let coordinator: Coordinator
    private var observation: AnyCancellable?
    private var hideTimer: Timer?
    private var escMonitors: [Any] = []

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: OverlayView(coordinator: coordinator))
        // receive(on:) defers to after SwiftUI re-renders, so fittingSize matches the new phase.
        observation = coordinator.$phase.receive(on: RunLoop.main).sink { [weak self] phase in self?.update(phase) }
    }

    private func update(_ phase: Coordinator.Phase) {
        hideTimer?.invalidate()
        switch phase {
        case .idle:
            hide()
        case .working, .preview:
            show()
        case .done:
            show()
            hide(after: 2.5)
        case .failed:
            show()
            hide(after: 5)
        }
    }

    private func show() {
        if let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
        if !panel.isVisible, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 80))
        }
        panel.orderFrontRegardless()
        guard escMonitors.isEmpty else { return }
        // Esc reaches us only via a global monitor, because the panel never becomes key.
        let onEsc: (NSEvent) -> Void = { [weak self] e in
            guard e.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self else { return }
                if case .working = self.coordinator.phase { self.coordinator.cancel() } else { self.coordinator.dismiss() }
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: onEsc) { escMonitors.append(m) }
    }

    private func hide(after seconds: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.coordinator.dismiss() }
        }
    }

    private func hide() {
        panel.orderOut(nil)
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
    }
}

/// Lets the first click hit a button even though the panel is never key.
private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct OverlayView: View {
    @ObservedObject var coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch coordinator.phase {
            case .idle:
                EmptyView()
            case .working(let mode, let partial):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(mode.title)…").font(.headline)
                    Spacer()
                    Text("esc to cancel").font(.caption).foregroundStyle(.secondary)
                }
                if !partial.isEmpty {
                    Text(partial).font(.callout).foregroundStyle(.secondary).lineLimit(3).truncationMode(.head)
                }
            case .done(let outcome):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(outcome == .replaced ? "Replaced · ⌘Z to undo" : "Copied. Paste it into your terminal.")
                    Spacer()
                    if outcome == .replaced { Button("Copy original", action: copyOriginal).controlSize(.small) }
                }
            case .preview(let text, let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                ScrollView { Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
                HStack {
                    Spacer()
                    Button("Discard") { coordinator.dismiss() }
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); coordinator.dismiss() }
                    Button("Replace") { coordinator.acceptPreview() }.keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func copyOriginal() {
        guard let original = coordinator.original else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(original, forType: .string)
    }
}
