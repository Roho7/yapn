import DictationCore
import Foundation

/// Where a take's samples come from: the microphone, or a recorded file for `--selftest`.
@MainActor
protocol AudioSource {
    func start() throws
    /// 16 kHz mono Float32.
    func stop() -> [Float]
}

extension AudioRecorder: AudioSource {}

struct FileAudioSource: AudioSource {
    let samples: [Float]
    func start() {}
    func stop() -> [Float] { samples }
}

/// Parakeet throws on fewer than 0.3 s of samples. A press that passed the reducer's
/// minimum can still capture slightly less because the input engine takes a moment to start.
func padToMinimum(_ samples: [Float]) -> [Float] {
    let minimum = Int(targetSampleRate * minimumPressSeconds)
    guard samples.count < minimum else { return samples }
    return samples + Array(repeating: 0, count: minimum - samples.count)
}
