public func makeEngine(_ variant: EngineVariant, vocab: [String]) -> any TranscriptionEngine {
    switch variant.model {
    case .parakeetV2:
        return ParakeetEngine(variant: variant, vocab: vocab)
    }
}
