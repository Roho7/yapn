import CoreGraphics
import Foundation

/// A damped spring parameterised like SwiftUI's: `response` is the period in seconds,
/// `damping` the damping fraction (1 is critical, lower overshoots).
struct Spring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat

    init(_ value: CGFloat) {
        self.value = value
        target = value
    }

    struct Tuning {
        let response: CGFloat
        let damping: CGFloat
    }

    mutating func step(_ dt: CGFloat, _ tuning: Tuning) {
        let stiffness = pow(2 * .pi / tuning.response, 2)
        let friction = 4 * .pi * tuning.damping / tuning.response
        velocity += (-stiffness * (value - target) - friction * velocity) * dt
        value += velocity * dt
    }

    var isSettled: Bool { abs(value - target) < 0.25 && abs(velocity) < 2 }
}

/// The indicator's silhouette: the notch's own outline at some size. Flat top flush with the screen
/// edge, straight sides, rounded bottom corners, and concave shoulders flaring into the menu bar.
struct NotchShape {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var shoulder: CGFloat

    /// The hardware notch's corners. On a screen without one the shape starts as nothing at the top edge.
    static func rest(_ notch: CGSize) -> NotchShape {
        notch.width > 0
            ? NotchShape(width: notch.width, height: notch.height, radius: 12, shoulder: 6)
            : NotchShape(width: 0, height: 0, radius: 0, shoulder: 0)
    }

    static let open = (radius: CGFloat(22), shoulder: CGFloat(9))

    static func target(_ phase: IndicatorPhase, notch: CGSize, level: CGFloat, time: Double) -> (width: CGFloat, height: CGFloat) {
        let breathe = CGFloat(sin(time * 1.9))
        switch phase {
        case .hidden:
            let rest = rest(notch)
            return (rest.width, rest.height)
        case .listening:
            return (max(notch.width + 96, 200) + level * 10 + breathe * 2, notch.height + 30 + level * 5)
        case .transcribing:
            return (max(notch.width + 64, 170), notch.height + 26 + breathe * 1.5)
        }
    }
}

/// Opening settles with a slight overshoot; retracting pulls straight back into the notch.
private enum Tunings {
    static let open = (width: Spring.Tuning(response: 0.5, damping: 0.68), height: Spring.Tuning(response: 0.46, damping: 0.68))
    static let retract = (width: Spring.Tuning(response: 0.36, damping: 0.92), height: Spring.Tuning(response: 0.34, damping: 0.92))
}

/// One rendered frame, in view coordinates with the origin at the top-left of the canvas.
struct NotchFrame {
    var notch: CGSize
    var shape: NotchShape
    /// 0 at rest, 1 once the shape has grown to its open size.
    var openness: CGFloat
    /// Bar heights 0...1 from the centre bar outwards.
    var bars: [CGFloat]
    var barsAlpha: CGFloat
    var antsAlpha: CGFloat
    var time: Double
}

/// Microphone level history, newest first. One entry per `updateLevel`, so the bars ripple outwards.
struct LevelMeter {
    static let count = 9
    private(set) var history = [CGFloat](repeating: 0, count: count)
    private var peak = noiseFloor + minimumSpan

    private static let noiseFloor: CGFloat = 0.1
    private static let minimumSpan: CGFloat = 0.2

    /// `level` is 0...1 on a dB scale with -50 dBFS at 0. Speech loudness depends on the mic and
    /// distance (a MacBook mic at arm's length peaks around 0.35), so bars scale against a slowly
    /// decaying recent peak rather than a fixed loudness.
    mutating func push(_ level: Float) {
        let level = CGFloat(level)
        peak = max(level, peak * 0.995, Self.noiseFloor + Self.minimumSpan)
        let voiced = min(max((level - Self.noiseFloor) / (peak - Self.noiseFloor), 0), 1)
        history.removeLast()
        history.insert(voiced, at: 0)
    }

    mutating func clear() {
        history = [CGFloat](repeating: 0, count: Self.count)
        peak = Self.noiseFloor + Self.minimumSpan
    }
}

/// The shape's physics and the waveform's smoothing, advanced once per displayed frame.
@MainActor
final class NotchMotion {
    private(set) var phase = IndicatorPhase.hidden
    let notch: CGSize
    var meter = LevelMeter()

    private let rest: NotchShape
    private var width: Spring
    private var height: Spring
    private var bars = [CGFloat](repeating: 0, count: LevelMeter.count)
    private var barsAlpha: CGFloat = 0
    private var antsAlpha: CGFloat = 0
    private var lastTime: Double?

    init(notch: CGSize) {
        self.notch = notch
        rest = NotchShape.rest(notch)
        width = Spring(rest.width)
        height = Spring(rest.height)
    }

    func setPhase(_ next: IndicatorPhase) {
        if next == .listening, phase != .listening { meter.clear() }
        phase = next
    }

    var isRetracted: Bool {
        phase == .hidden && width.isSettled && height.isSettled
    }

    func advance(to time: Double) -> NotchFrame {
        let dt = CGFloat(min(max(time - (lastTime ?? time), 0), 1.0 / 30))
        lastTime = time
        let level = meter.history.prefix(4).reduce(0, +) / 4
        let target = NotchShape.target(phase, notch: notch, level: phase == .listening ? level : 0, time: time)
        width.target = target.width
        height.target = target.height

        let tuning = phase == .hidden ? Tunings.retract : Tunings.open
        let substeps = max(1, Int((dt * 480).rounded(.up)))
        let h = dt / CGFloat(substeps)
        for _ in 0..<substeps {
            width.step(h, tuning.width)
            height.step(h, tuning.height)
        }

        let growth = (height.value - rest.height) / (notch.height + 26 - rest.height)
        let openness = min(max(growth, 0), 1)
        let shape = NotchShape(
            width: max(width.value, 0),
            height: max(height.value, 0),
            radius: rest.radius + (NotchShape.open.radius - rest.radius) * openness,
            shoulder: rest.shoulder + (NotchShape.open.shoulder - rest.shoulder) * openness
        )
        barsAlpha = ease(barsAlpha, to: phase == .listening ? 1 : 0, dt: dt, tau: 0.09)
        antsAlpha = ease(antsAlpha, to: phase == .transcribing ? 1 : 0, dt: dt, tau: 0.14)
        for k in bars.indices {
            let ripple = 0.5 + 0.5 * CGFloat(sin(time * 2.6 - Double(k) * 0.65))
            let idle = 0.12 + 0.07 * ripple
            let envelope = 1 - 0.5 * pow(CGFloat(k) / CGFloat(bars.count - 1), 1.6)
            let goal = idle + (1 - idle) * meter.history[k] * envelope
            bars[k] = ease(bars[k], to: goal, dt: dt, tau: goal > bars[k] ? 0.045 : 0.13)
        }

        return NotchFrame(
            notch: notch,
            shape: shape,
            openness: openness,
            bars: bars,
            barsAlpha: barsAlpha * pow(max(openness - 0.5, 0) * 2, 2),
            antsAlpha: antsAlpha * openness,
            time: time
        )
    }

    private func ease(_ value: CGFloat, to target: CGFloat, dt: CGFloat, tau: CGFloat) -> CGFloat {
        value + (target - value) * (1 - exp(-dt / tau))
    }
}
