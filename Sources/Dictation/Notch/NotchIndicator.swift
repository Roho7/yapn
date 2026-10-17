import AppKit
import DictationCore
import SwiftUI

/// The notch grows outwards into a larger notch: a live waveform while listening, marching ants while
/// transcribing. On a screen without a notch the shape grows out of the top centre of the menu bar.
@MainActor
final class NotchIndicator: StatusIndicator {
    /// Room around the largest shape for spring overshoot and the shoulders.
    private static let canvas = (sideMargin: CGFloat(90), height: CGFloat(110))

    private let panel: NSPanel
    private let model: NotchModel
    private var geometry: NotchGeometry

    init() {
        geometry = NotchGeometry.current()
        model = NotchModel(notch: geometry.notch)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Above the menu bar and status items (both at most .statusBar) so the shape reads as one piece
        // with the notch, and below pop-up menus so it never covers one the user opens.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        model.onRetracted = { [weak self] in self?.retracted() }
        place()
    }

    func show(_ phase: IndicatorPhase) {
        if phase != .hidden, !model.isRunning {
            let current = NotchGeometry.current()
            if current != geometry {
                geometry = current
                model.motion = NotchMotion(notch: current.notch)
                place()
            }
            panel.orderFrontRegardless()
            model.isRunning = true
        }
        model.motion.setPhase(phase)
    }

    func updateLevel(_ level: Float) {
        model.motion.meter.push(level)
    }

    private func retracted() {
        model.isRunning = false
        panel.orderOut(nil)
    }

    private func place() {
        let width = max(geometry.notch.width, 200) + 2 * Self.canvas.sideMargin
        let height = geometry.notch.height + Self.canvas.height
        panel.setFrame(
            NSRect(x: (geometry.midX - width / 2).rounded(), y: geometry.screenFrame.maxY - height, width: width, height: height),
            display: false
        )
    }

    /// Loops hidden, listening with a synthetic voice, transcribing, hidden. Needs no permissions.
    @discardableResult
    static func runDemo() -> Task<Void, Never> {
        let indicator = NotchIndicator()
        return Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                indicator.show(.listening)
                let start = Date()
                while Date().timeIntervalSince(start) < 3.6 {
                    indicator.updateLevel(syntheticLevel(at: Date().timeIntervalSince(start)))
                    try? await Task.sleep(for: .milliseconds(33))
                }
                indicator.show(.transcribing)
                try? await Task.sleep(for: .seconds(2.2))
                indicator.show(.hidden)
            }
        }
    }

    /// Holds the listening pose and drives the waveform from the real microphone, for tuning the
    /// animation by voice. Needs only microphone access.
    static func runLive() {
        let indicator = NotchIndicator()
        let recorder = AudioRecorder()
        recorder.onLevel = { level in
            Task { @MainActor in indicator.updateLevel(level) }
        }
        Task { @MainActor in
            guard await AudioRecorder.requestAccess() else {
                FileHandle.standardError.write(Data("notch-live: microphone access denied\n".utf8))
                exit(1)
            }
            do {
                try recorder.start()
            } catch {
                FileHandle.standardError.write(Data("notch-live: \(error)\n".utf8))
                exit(1)
            }
            indicator.show(.listening)
            liveRecorder = recorder
        }
    }

    private static var liveRecorder: AudioRecorder?

    /// Syllables at about 5 Hz inside words, with a pause between phrases.
    private static func syntheticLevel(at t: Double) -> Float {
        let phrase = t.truncatingRemainder(dividingBy: 1.8) < 1.35 ? 1.0 : 0.0
        let syllable = abs(sin(t * 15.7)) * (0.7 + 0.3 * sin(t * 2.3))
        return Float(0.25 + phrase * (0.25 + 0.4 * syllable) + Double.random(in: -0.03...0.03))
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// AppKit nudges windows below the menu bar; this one belongs in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
