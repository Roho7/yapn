import SwiftUI

@MainActor
@Observable
final class NotchModel {
    /// Drives the display link. False only once the shape is back inside the notch, so a hidden
    /// indicator costs no CPU.
    var isRunning = false
    @ObservationIgnored var motion: NotchMotion
    @ObservationIgnored var onRetracted: () -> Void = {}

    init(notch: CGSize) {
        motion = NotchMotion(notch: notch)
    }
}

struct NotchView: View {
    let model: NotchModel

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.isRunning)) { timeline in
            Canvas { context, size in
                let motion = model.motion
                let frame = motion.advance(to: timeline.date.timeIntervalSinceReferenceDate)
                NotchRenderer.draw(frame, in: &context, width: size.width)
                if motion.isRetracted {
                    Task { @MainActor in
                        if model.motion === motion, motion.isRetracted { model.onRetracted() }
                    }
                }
            }
        }
    }
}

enum NotchRenderer {
    /// How far inside the outline the transcribing ants run.
    static let antsInset: CGFloat = 5.5

    static func draw(_ frame: NotchFrame, in context: inout GraphicsContext, width: CGFloat) {
        let midX = width / 2
        drawBody(frame, midX: midX, in: &context)
        if frame.barsAlpha > 0.01 { drawWaveform(frame, midX: midX, in: &context) }
        if frame.antsAlpha > 0.01 { drawAnts(frame, midX: midX, in: &context) }
    }

    /// The body is drawn twice: a faint white copy, then the black one lifted a little, which leaves a
    /// glassy rim exactly on the downward-facing edges of the outline.
    private static func drawBody(_ frame: NotchFrame, midX: CGFloat, in context: inout GraphicsContext) {
        let lift: CGFloat = 1.2
        var body = outline(frame.shape, midX: midX, inset: 0)
        body.addLine(to: CGPoint(x: midX + frame.shape.width / 2 + frame.shape.shoulder, y: -lift - 1))
        body.addLine(to: CGPoint(x: midX - frame.shape.width / 2 - frame.shape.shoulder, y: -lift - 1))
        body.closeSubpath()
        context.fill(body, with: .color(.white.opacity(0.24 * frame.openness)))
        context.fill(body.offsetBy(dx: 0, dy: -lift), with: .color(.black))
    }

    /// The silhouette from the top-left shoulder down, along the bottom and up to the top-right
    /// shoulder, as an open path. `inset` gives the parallel curve that far inside it: every corner
    /// keeps its centre, so the shoulders grow by `inset` and the bottom corners shrink by it.
    static func outline(_ shape: NotchShape, midX: CGFloat, inset: CGFloat) -> Path {
        let left = midX - shape.width / 2
        let right = midX + shape.width / 2
        let bottom = shape.height - inset
        let s = shape.shoulder
        let r = min(max(shape.radius - inset, 0), max(right - left - 2 * inset, 0) / 2, max(bottom - s, 0))
        // Where the shoulder's parallel arc, centred s below and s outside the top corner, meets the top edge.
        let sweep = Angle.radians(s > 0 ? asin(s / (s + inset)) : 0)
        var path = Path()
        path.addArc(center: CGPoint(x: left - s, y: s), radius: s + inset, startAngle: -sweep, endAngle: .zero, clockwise: false)
        path.addArc(tangent1End: CGPoint(x: left + inset, y: bottom), tangent2End: CGPoint(x: midX, y: bottom), radius: r)
        path.addArc(tangent1End: CGPoint(x: right - inset, y: bottom), tangent2End: CGPoint(x: right - inset, y: s), radius: r)
        path.addArc(center: CGPoint(x: right + s, y: s), radius: s + inset, startAngle: .radians(.pi), endAngle: .radians(.pi) + sweep, clockwise: false)
        return path
    }

    private static func drawWaveform(_ frame: NotchFrame, midX: CGFloat, in context: inout GraphicsContext) {
        let lane = frame.shape.height - frame.notch.height
        let centerY = frame.notch.height + lane / 2 - 1
        let maxHeight = min(20, max(lane - 10, 0))
        let barWidth: CGFloat = 3
        let pitch: CGFloat = 6.5
        var bars = Path()
        for (k, value) in frame.bars.enumerated() {
            let height = max(barWidth, value * maxHeight)
            for side in k == 0 ? [CGFloat(0)] : [-1, 1] {
                let x = midX + side * CGFloat(k) * pitch - barWidth / 2
                bars.addRoundedRect(
                    in: CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height),
                    cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                )
            }
        }
        context.fill(bars, with: .color(.white.opacity(0.92 * frame.barsAlpha)))
    }

    /// Dashes marching down the left wall, along the bottom and up the right wall, emerging from
    /// and disappearing into the notch, concentric with the outline.
    private static func drawAnts(_ frame: NotchFrame, midX: CGFloat, in context: inout GraphicsContext) {
        let phase = CGFloat(frame.time.truncatingRemainder(dividingBy: 100)) * -26
        context.stroke(
            outline(frame.shape, midX: midX, inset: antsInset),
            with: .color(.white.opacity(0.88 * frame.antsAlpha)),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 5], dashPhase: phase)
        )
    }
}
