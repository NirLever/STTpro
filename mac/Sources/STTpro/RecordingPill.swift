import AppKit
import Combine
import SwiftUI

/// Floating recording pill (port of RecordingIndicator.xaml/.cs) plus the
/// "Recording with: <prompt>" toast (PromptToast.xaml). Bottom-centre of the
/// screen the target app is on; never takes focus, but its stop / cancel
/// buttons are clickable.
@MainActor
final class RecordingHUD {
    enum Phase: Equatable {
        case hidden
        case recording(prompt: String?)
        case working(String)
        case message(String, isError: Bool)
    }

    let model = PillModel()
    private var panel: NSPanel?
    private var host: NSHostingView<PillView>?
    private var toast: ToastPanel?
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var targetScreen: NSScreen?

    var enabled = true
    var onStop: (() -> Void)? { didSet { model.onStop = onStop } }
    var onCancel: (() -> Void)? { didSet { model.onCancel = onCancel } }

    init() {
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.resize() }
            .store(in: &cancellables)
    }

    /// Screen of the app the user is dictating into (Windows: target window's monitor).
    func setTarget(pid: pid_t?) {
        targetScreen = pid.flatMap(Self.screen(forPID:)) ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }

    func show(_ phase: Phase) {
        hideTask?.cancel()
        switch phase {
        case .hidden:
            hide(); return
        case .recording:
            if !enabled { hide(); return }
            model.startRecording()
        case .working(let label):
            if !enabled { hide(); return }
            model.startWorking(label)
        case .message(_, let isError):
            if !enabled && !isError { hide(); return }
        }
        model.phase = phase
        let panel = self.panel ?? makePanel()
        self.panel = panel
        resize()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if case .message(_, let isError) = phase {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(isError ? 5 : 1.6))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func setPrompt(_ name: String?) { model.prompt = name }

    func setLevel(_ level: Float) { model.setLevel(level) }

    func showPromptToast(_ text: String) {
        guard enabled else { return }
        let toast = self.toast ?? ToastPanel()
        self.toast = toast
        toast.show(text, on: targetScreen ?? NSScreen.main)
    }

    func hide() {
        hideTask?.cancel()
        model.stop()
        model.phase = .hidden
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: PillView(model: model))
        panel.contentView = host
        self.host = host
        return panel
    }

    private func resize() {
        guard let panel, let host, panel.isVisible || model.phase != .hidden else { return }
        let size = host.fittingSize
        let screen = targetScreen ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let w = max(size.width, 60), h = max(size.height, 44)
        panel.setFrame(NSRect(x: frame.midX - w / 2, y: frame.minY + 24, width: w, height: h), display: true)
    }

    static func screen(forPID pid: pid_t) -> NSScreen? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 50, h > 50 else { continue }
            // CG coordinates are top-left based on the primary display.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let center = NSPoint(x: x + w / 2, y: primaryHeight - (y + h / 2))
            return NSScreen.screens.first { $0.frame.contains(center) }
        }
        return nil
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Model (waveform logic ported from RecordingIndicator.xaml.cs)

@MainActor
final class PillModel: ObservableObject {
    @Published var phase: RecordingHUD.Phase = .hidden
    @Published var elapsed = "0:00"
    @Published var bars = [CGFloat](repeating: PillModel.barMin, count: 10)
    @Published var noSignal = false
    @Published var prompt: String?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    static let barMin: CGFloat = 3
    static let barMax: CGFloat = 21
    private static let noiseGate = 0.012
    private static let gain = 2.6

    private var startedAt = Date()
    private var currentLevel: Float = 0
    private var lastAudio = Date()
    private var lastSignal = Date()
    private var wavePhase = 0.0
    private var waveTimer: Timer?
    private var clockTimer: Timer?
    private var recordingActive = false

    func startRecording() {
        stop()
        startedAt = Date()
        elapsed = "0:00"
        currentLevel = 0
        wavePhase = 0
        lastAudio = Date()
        lastSignal = Date()
        noSignal = false
        bars = [CGFloat](repeating: Self.barMin, count: 10)
        recordingActive = true
        clockTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        waveTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickWave() }
        }
        RunLoop.main.add(clockTimer!, forMode: .common)
        RunLoop.main.add(waveTimer!, forMode: .common)
    }

    func startWorking(_ label: String) {
        stop()
        noSignal = false
    }

    func stop() {
        clockTimer?.invalidate(); clockTimer = nil
        waveTimer?.invalidate(); waveTimer = nil
        recordingActive = false
    }

    /// Attack instantly, release quickly — the bars track speech closely.
    func setLevel(_ level: Float) {
        lastAudio = Date()
        if level > currentLevel { currentLevel = level } else { currentLevel += (level - currentLevel) * 0.32 }
        if Double(level) > Self.noiseGate { lastSignal = Date() }
    }

    private func tickClock() {
        let s = Int(Date().timeIntervalSince(startedAt))
        elapsed = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                            : String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func shape(_ level: Double) -> Double {
        guard level > noiseGate else { return 0 }
        return pow(min(1, (level - noiseGate) * gain), 0.55)
    }

    private func tickWave() {
        wavePhase += 0.42
        let energy = Self.shape(Double(currentLevel))
        var next = bars
        for i in 0..<next.count {
            let envelope = 0.45 + 0.55 * sin(Double.pi * (Double(i) + 0.5) / Double(next.count))
            let ripple = 0.78 + 0.22 * sin(wavePhase + Double(i) * 0.7)
            let target = Self.barMin + (Self.barMax - Self.barMin) * CGFloat(energy * envelope * ripple)
            let k: CGFloat = target > next[i] ? 0.85 : 0.30
            next[i] += (target - next[i]) * k
        }
        bars = next
        if Date().timeIntervalSince(lastAudio) > 0.25 { currentLevel *= 0.70 }
        let silent = recordingActive && Date().timeIntervalSince(lastSignal) > 2.5
        if silent != noSignal { noSignal = silent }
    }
}

// MARK: - Views

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        content
            .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(Capsule().fill(Theme.bgElevated))
            .overlay(Capsule().strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .recording(let initialPrompt):
            HStack(spacing: 0) {
                PulsingDot().padding(.trailing, 8)
                Text(model.elapsed).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 3) {
                    ForEach(0..<model.bars.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.accentBlue).frame(width: 3, height: model.bars[i])
                    }
                }
                .frame(height: 22)
                .padding(.leading, 10).padding(.trailing, 2)
                if model.noSignal {
                    Text("no mic signal").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accentOrange)
                        .padding(.leading, 8)
                }
                if let prompt = model.prompt ?? initialPrompt, !prompt.isEmpty {
                    Text(prompt).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accentBlue).padding(.leading, 6)
                }
                PillButton(help: "Stop and transcribe", action: { model.onStop?() }) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.textSecondary).frame(width: 9, height: 9)
                }
                .padding(.leading, 10)
                PillButton(help: "Cancel and discard", action: { model.onCancel?() }) {
                    Text("×").font(.system(size: 15)).foregroundStyle(Theme.textMuted).offset(y: -1)
                }
                .padding(.horizontal, 2)
            }
        case .working(let label):
            HStack(spacing: 0) {
                PulsingDot().padding(.trailing, 8)
                Text(model.elapsed).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accentBlue).padding(.leading, 6)
                    .padding(.trailing, 4)
            }
        case .message(let text, let isError):
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Theme.accentOrange : Theme.accentGreen)
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).frame(maxWidth: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 4)
        }
    }
}

/// Red dot fading 1.0 ↔ 0.3 every 0.8 s (sine ease), like the Windows storyboard.
private struct PulsingDot: View {
    @ViewState private var dim = false
    var body: some View {
        Circle().fill(Color(red: 1, green: 0.231, blue: 0.188)).frame(width: 10, height: 10)
            .opacity(dim ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

private struct PillButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            label.frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? Theme.hoverOverlay : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Prompt toast

@MainActor
private final class ToastPanel {
    final class Model: ObservableObject { @Published var text = "" }
    private let model = Model()
    private let panel: NSPanel
    private let host: NSHostingView<ToastView>
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        host = NSHostingView(rootView: ToastView(model: model))
        panel.contentView = host
    }

    func show(_ text: String, on screen: NSScreen?) {
        hideTask?.cancel()
        model.text = text
        let size = host.fittingSize
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 80, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.panel.orderOut(nil) }
            })
        }
    }

    struct ToastView: View {
        @ObservedObject var model: Model
        var body: some View {
            HStack(spacing: 8) {
                Circle().fill(Theme.accentRed).frame(width: 8, height: 8)
                Text(model.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgElevated))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.32), radius: 10, y: 3)
            .padding(14)
            .fixedSize()
        }
    }
}
