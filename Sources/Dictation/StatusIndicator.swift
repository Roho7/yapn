import DictationCore

enum IndicatorPhase: Equatable {
    case hidden
    case listening
    case transcribing
}

extension IndicatorPhase {
    init(_ state: DictationState) {
        switch state {
        case .recording: self = .listening
        case .transcribing, .inserting: self = .transcribing
        case .loading, .idle, .failed: self = .hidden
        }
    }
}

/// The on-screen recording indicator. AppController calls `show` whenever the phase changes and
/// `updateLevel` about every 20–30 ms while recording. Implementations must never take focus.
@MainActor
protocol StatusIndicator {
    func show(_ phase: IndicatorPhase)
    /// Microphone level, 0...1 on a dB scale (-50 dBFS and below is 0, 0 dBFS is 1).
    func updateLevel(_ level: Float)
}

extension StatusIndicator {
    func updateLevel(_ level: Float) {}
}

struct NoStatusIndicator: StatusIndicator {
    func show(_ phase: IndicatorPhase) {}
}
