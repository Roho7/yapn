@preconcurrency import AVFoundation
import os

/// Microphone level for a live indicator. The input tap only delivers ~100 ms buffers, so the level
/// comes from a sink node on the render thread (512-frame callbacks, ~10.7 ms at 48 kHz). That thread
/// must not allocate or block, so it only does arithmetic and stores the latest window; a timer on
/// an ordinary queue hands each new window to `onLevel`.
final class LevelMeter: @unchecked Sendable {
    static let window: Double = 0.02

    private(set) lazy var sink = AVAudioSinkNode { [unowned self] _, frameCount, bufferList in
        accumulate(bufferList, frames: Int(frameCount))
        return noErr
    }

    private let latest = OSAllocatedUnfairLock(initialState: (window: 0, level: Float(0)))
    private let queue = DispatchQueue(label: "LevelMeter", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var delivered = 0
    // Render-thread only.
    private var windowFrames = 960
    private var sumOfSquares: Float = 0
    private var framesInWindow = 0
    private var windowsDone = 0

    func start(sampleRate: Double, onLevel: (@Sendable (Float) -> Void)?) {
        windowFrames = max(1, Int(sampleRate * Self.window))
        sumOfSquares = 0
        framesInWindow = 0
        guard let onLevel else { return }
        delivered = latest.withLock { $0.window }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [unowned self] in
            let (window, level) = latest.withLock { $0 }
            guard window != delivered else { return }
            delivered = window
            onLevel(level)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func accumulate(_ bufferList: UnsafePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let count = min(frames, Int(first.mDataByteSize) / MemoryLayout<Float>.size)
        for i in 0..<count {
            sumOfSquares += data[i] * data[i]
        }
        framesInWindow += count
        guard framesInWindow >= windowFrames else { return }
        let level = normalisedLevel(rms: (sumOfSquares / Float(framesInWindow)).squareRoot())
        sumOfSquares = 0
        framesInWindow = 0
        windowsDone += 1
        let done = windowsDone
        latest.withLock { $0 = (done, level) }
    }
}

/// -50 dBFS and below is 0, 0 dBFS is 1, linear in dB between: speech then spans most of the range.
func normalisedLevel(rms: Float) -> Float {
    let decibels = 20 * log10(max(rms, 1e-9))
    return min(1, max(0, (decibels + 50) / 50))
}
