import AppKit
import SwiftUI

/// Small floating pill near the bottom of the screen showing recording /
/// transcribing state. It never takes focus, so the target app stays active.
@MainActor
final class RecordingHUD {
    enum Phase: Equatable {
        case hidden
        case recording(prompt: String?)
        case working(String)
        case message(String, isError: Bool)
    }

    final class Model: ObservableObject {
        @Published var phase: Phase = .hidden
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    var enabled = true

    func show(_ phase: Phase) {
        hideTask?.cancel()
        if case .hidden = phase { hide(); return }
        // Errors are always shown, even with the indicator turned off.
        if !enabled, case .message(_, false) = phase { hide(); return }
        if !enabled, case .recording = phase { hide(); return }
        if !enabled, case .working = phase { hide(); return }
        model.phase = phase
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()

        if case .message(_, let isError) = phase {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(isError ? 5 : 1.6))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        model.phase = .hidden
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = panel.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 60))
    }
}

private struct HUDView: View {
    @ObservedObject var model: RecordingHUD.Model

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .recording(let prompt):
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                    .shadow(color: .red.opacity(0.7), radius: 4)
                Text("Recording").font(.system(size: 13, weight: .semibold))
                if let prompt {
                    Text("· \(prompt)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 13, weight: .medium))
            }
        case .message(let text, let isError):
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .orange : .green)
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
        }
    }
}
