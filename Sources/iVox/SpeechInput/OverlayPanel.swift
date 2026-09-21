// Based on OpenWritr (https://github.com/trsdn/OpenWritr), MIT License

import Cocoa
import Observation
import SwiftUI

enum OverlayState: Sendable {
    case listening
    case transcribing
    case done
    case error(String)
}

// 所有方法只从 MainActor 调用（调用方负责）
final class OverlayPanel: @unchecked Sendable {
    private static let panelSize = NSSize(width: 248, height: 66)

    private var panel: NSPanel?
    private let presentation = OverlayPresentation()

    func show(state: OverlayState) {
        if panel == nil {
            createPanel()
        }

        presentation.setState(state)
        presentation.isVisible = true
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func updateAudioLevel(_ level: Float) {
        presentation.updateAudioLevel(level)
    }

    func dismiss() {
        presentation.isVisible = false
        presentation.resetAudioLevel()
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(
            rootView: OverlayContentView(presentation: presentation)
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        hostingView.layer?.borderWidth = 0

        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.isOpaque = false
        panel.contentView?.layer?.borderWidth = 0

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panel.frame.width / 2
        let y = visibleFrame.minY + 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@Observable
private final class OverlayPresentation: @unchecked Sendable {
    var state: OverlayState = .listening
    var rawRMS: CGFloat = 0
    var isVisible = false

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    var isProcessing: Bool {
        if case .transcribing = state { return true }
        return false
    }

    var isError: Bool {
        if case .error = state { return true }
        return false
    }

    func setState(_ newState: OverlayState) {
        state = newState
        if !isListening {
            resetAudioLevel()
        }
    }

    func updateAudioLevel(_ level: Float) {
        guard isListening else { return }
        rawRMS = CGFloat(min(max(level, 0), 1))
    }

    func resetAudioLevel() {
        rawRMS = 0
    }
}

private struct OverlayContentView: View {
    private static let barCount = 22

    @Bindable var presentation: OverlayPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: !presentation.isVisible
                    || reduceMotion
                    || (!presentation.isListening && !presentation.isProcessing)
            )
        ) { context in
            capsule(phase: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: 248, height: 66)
    }

    private func capsule(phase: TimeInterval) -> some View {
        HStack(spacing: 12) {
            barField(phase: phase)
                .frame(width: presentation.isError ? 48 : 108)
                .clipped()

            HStack(spacing: 5) {
                icon
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(presentation.isError ? 2 : 1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(accentColor)
            .frame(
                width: presentation.isError ? 138 : 78,
                alignment: .leading
            )
        }
        .padding(.horizontal, 14)
        .frame(width: 228, height: 46)
        .background {
            Capsule(style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedWhite: 0.075, alpha: 0.96)))
        }
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private func barField(phase: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(barColor)
                    .frame(width: 3, height: barHeight(at: index, phase: phase))
            }
        }
        .frame(width: 108, height: 30)
    }

    private func barHeight(at index: Int, phase: TimeInterval) -> CGFloat {
        let t = CGFloat(index) / CGFloat(Self.barCount - 1)
        let centered = abs(t - 0.5) * 2
        let envelope = exp(-centered * centered * 2.2)

        switch presentation.state {
        case .listening:
            let amplitude = min(1, 0.20 + sqrt(presentation.rawRMS) * 2.2)
            return max(4, envelope * shimmer(t: t, phase: phase) * amplitude * 30)
        case .transcribing:
            return max(4, envelope * shimmer(t: t, phase: phase * 0.88) * 23)
        case .done:
            let completionShape = 1 - abs(t - 0.5) * 0.9
            return max(4, envelope * completionShape * 15)
        case .error:
            let alternating = index.isMultiple(of: 2) ? 0.72 : 0.42
            return max(4, envelope * alternating * 16)
        }
    }

    private func shimmer(t: CGFloat, phase: TimeInterval) -> CGFloat {
        let phase = CGFloat(phase)
        let waveOne = sin(phase * 5.5 + t * 7.0)
        let waveTwo = sin(phase * 3.2 - t * 4.0)
        let wobble = (waveOne * 0.6 + waveTwo * 0.4) * 0.5 + 0.5
        return 0.35 + 0.65 * wobble
    }

    private var barColor: Color {
        switch presentation.state {
        case .listening:
            return .white
        case .transcribing:
            return Color(red: 0.45, green: 0.86, blue: 1)
        case .done:
            return Color(red: 0.42, green: 0.86, blue: 0.57).opacity(0.82)
        case .error:
            return Color(red: 1, green: 0.58, blue: 0.38).opacity(0.82)
        }
    }

    private var accentColor: Color {
        switch presentation.state {
        case .listening:
            return .white.opacity(0.82)
        case .transcribing:
            return Color(red: 0.60, green: 0.90, blue: 1)
        case .done:
            return Color(red: 0.52, green: 0.92, blue: 0.64)
        case .error:
            return Color(red: 1, green: 0.65, blue: 0.48)
        }
    }

    private var title: String {
        switch presentation.state {
        case .listening:
            return "聆听中…"
        case .transcribing:
            return "识别中…"
        case .done:
            return "已粘贴"
        case .error(let message):
            return message.isEmpty ? "识别失败" : message
        }
    }

    private var accessibilityLabel: String {
        switch presentation.state {
        case .listening:
            return "聆听中"
        case .transcribing:
            return "识别中"
        case .done:
            return "识别结果已粘贴"
        case .error:
            return "语音识别失败"
        }
    }

    private var accessibilityValue: String {
        if case .error(let message) = presentation.state {
            return message
        }
        return ""
    }

    @ViewBuilder
    private var icon: some View {
        switch presentation.state {
        case .listening:
            Image(systemName: "mic.fill")
        case .transcribing:
            Image(systemName: "waveform")
        case .done:
            Image(systemName: "checkmark")
        case .error:
            Image(systemName: "exclamationmark")
        }
    }
}
