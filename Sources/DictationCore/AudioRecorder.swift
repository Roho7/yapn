@preconcurrency import AVFoundation

public enum AudioRecorderError: Error, CustomStringConvertible {
    case microphoneDenied
    case noInputDevice

    public var description: String {
        switch self {
        case .microphoneDenied: "microphone access denied; allow it for this terminal in System Settings > Privacy & Security > Microphone"
        case .noInputDevice: "no audio input available (zero sample rate); check the input device and microphone permission"
        }
    }
}

/// Captures the default input at its native format and converts once on `stop()`
/// with the same path file loading uses, so live and recorded audio are processed identically.
public final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var chunks: [AVAudioPCMBuffer] = []
    private let meter = LevelMeter()

    /// Called about every 20 ms while recording with the input level, 0...1 on a dB scale
    /// (see `normalisedLevel`). Called on a background queue. Set it before `start()`.
    public var onLevel: (@Sendable (Float) -> Void)?

    public init() {
        engine.attach(meter.sink)
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw AudioRecorderError.microphoneDenied
        default: break
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInputDevice }

        lock.withLock { chunks = [] }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            // The engine reuses tap buffers, so each one is copied out.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let bytesPerChannel = Int(buffer.frameLength) * MemoryLayout<Float>.size
            if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    memcpy(destination[channel], source[channel], bytesPerChannel)
                }
            }
            lock.withLock { chunks.append(copy) }
        }
        engine.connect(engine.inputNode, to: meter.sink, format: format)
        meter.start(sampleRate: format.sampleRate, onLevel: onLevel)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            meter.stop()
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    /// Returns 16kHz mono Float32. Empty if nothing was captured or conversion failed.
    public func stop() -> [Float] {
        engine.stop()
        meter.stop()
        engine.inputNode.removeTap(onBus: 0)
        let captured = lock.withLock { chunks }
        lock.withLock { chunks = [] }
        guard let first = captured.first else { return [] }

        let total = captured.reduce(0) { $0 + Int($1.frameLength) }
        guard let joined = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)),
              let destination = joined.floatChannelData
        else { return [] }
        var offset = 0
        for chunk in captured {
            guard let source = chunk.floatChannelData else { continue }
            let frames = Int(chunk.frameLength)
            for channel in 0..<Int(chunk.format.channelCount) {
                memcpy(destination[channel] + offset, source[channel], frames * MemoryLayout<Float>.size)
            }
            offset += frames
        }
        joined.frameLength = AVAudioFrameCount(total)
        return (try? convertToTargetFormat(joined)) ?? []
    }
}
