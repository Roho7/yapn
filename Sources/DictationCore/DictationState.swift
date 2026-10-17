/// The push-to-talk lifecycle. Every UI surface (menu line, status indicator) renders from this value,
/// and `reduce` is the only place it changes.
public enum DictationState: Equatable, Sendable {
    case loading
    case idle
    /// `since` is the hotkey-down timestamp, in the same clock as the events (seconds since boot).
    case recording(since: Double)
    case transcribing
    case inserting
    case failed(String)
}

public enum DictationEvent: Equatable, Sendable {
    case engineReady
    case hotkeyDown(at: Double)
    case hotkeyUp(at: Double)
    case transcribed(String)
    case inserted
    case failed(String)
}

public enum DictationEffect: Equatable, Sendable {
    case startRecording
    case cancelRecording
    case stopAndTranscribe
    case insert(String)
}

/// Parakeet rejects audio shorter than 0.3 s, and a press that short is almost always an accidental tap.
public let minimumPressSeconds: Double = 0.3

public func reduce(_ state: DictationState, _ event: DictationEvent) -> (DictationState, [DictationEffect]) {
    switch (state, event) {
    case (.loading, .engineReady):
        return (.idle, [])
    case (.loading, .failed(let reason)):
        return (.failed(reason), [])

    case (.idle, .hotkeyDown(let at)), (.failed, .hotkeyDown(let at)):
        return (.recording(since: at), [.startRecording])

    case (.recording(let since), .hotkeyUp(let at)):
        if at - since < minimumPressSeconds { return (.idle, [.cancelRecording]) }
        return (.transcribing, [.stopAndTranscribe])
    case (.recording, .failed(let reason)):
        return (.failed(reason), [.cancelRecording])

    case (.transcribing, .transcribed(let text)):
        if text.allSatisfy(\.isWhitespace) { return (.idle, []) }
        return (.inserting, [.insert(text)])
    case (.transcribing, .failed(let reason)):
        return (.failed(reason), [])

    case (.inserting, .inserted):
        return (.idle, [])
    case (.inserting, .failed(let reason)):
        return (.failed(reason), [])

    default:
        return (state, [])
    }
}
