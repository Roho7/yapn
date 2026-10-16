@preconcurrency import AVFoundation

public enum AudioFileError: Error {
    case unsupportedFormat
    case conversionFailed(String)
}

public let targetSampleRate: Double = 16_000

public func loadSamples(from url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let inBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        throw AudioFileError.unsupportedFormat
    }
    try file.read(into: inBuffer)
    return try convertToTargetFormat(inBuffer)
}

/// Resamples and downmixes any PCM buffer to 16kHz mono Float32. Shared by file loading and live capture.
func convertToTargetFormat(_ inBuffer: AVAudioPCMBuffer) throws -> [Float] {
    let inFormat = inBuffer.format
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat)
    else { throw AudioFileError.unsupportedFormat }

    let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * targetSampleRate / inFormat.sampleRate) + 1024
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
        throw AudioFileError.unsupportedFormat
    }

    nonisolated(unsafe) var supplied = false
    var convertError: NSError?
    let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
        if supplied {
            inputStatus.pointee = .endOfStream
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return inBuffer
    }
    if status == .error {
        throw AudioFileError.conversionFailed(convertError?.localizedDescription ?? "unknown")
    }
    guard let channel = outBuffer.floatChannelData?[0] else { throw AudioFileError.unsupportedFormat }
    return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
}

/// 16-bit PCM RIFF/WAVE, 16kHz mono. Written atomically so a re-record never leaves a torn file.
public func writeWAV(_ samples: [Float], to url: URL) throws {
    let dataBytes = samples.count * 2
    var data = Data(capacity: 44 + dataBytes)

    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    let rate = UInt32(targetSampleRate)
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + dataBytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(rate)
    append(rate * 2)
    append(UInt16(2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(dataBytes))
    for sample in samples {
        append(Int16((max(-1, min(1, sample)) * 32767).rounded()))
    }
    try data.write(to: url, options: .atomic)
}
