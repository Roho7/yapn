public func makeEngine(_ variant: EngineVariant, vocab: [String]) -> any TranscriptionEngine {
    switch variant.model {
    case .whisperTurbo:
        return WhisperKitEngine(variant: variant, modelName: "openai_whisper-large-v3-v20240930_turbo", vocab: vocab)
    case .whisperSmallEn:
        return WhisperKitEngine(variant: variant, modelName: "openai_whisper-small.en", vocab: vocab)
    case .parakeetV2:
        return ParakeetEngine(variant: variant, vocab: vocab)
    }
}
