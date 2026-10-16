import Foundation
@preconcurrency import FluidAudio

public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let variant: EngineVariant
    private let vocab: [String]
    private var manager: AsrManager?
    private var session: VocabularyBoostingSession?
    private var models: AsrModels?
    private var ctcModels: CtcModels?

    public init(variant: EngineVariant, vocab: [String]) {
        self.variant = variant
        self.vocab = vocab
    }

    public func load() async throws -> LoadStats {
        let wantsBoost = variant.biased && !vocab.isEmpty

        let (_, downloadSeconds) = try await timed {
            _ = try await AsrModels.download(version: .v2)
            if wantsBoost { _ = try await CtcModels.download(variant: .ctc110m) }
        }
        logEngine("\(variant.id): download step \(fmt(downloadSeconds))s")

        let (_, firstLoadSeconds) = try await timed {
            _ = try await AsrModels.downloadAndLoad(version: .v2)
            if wantsBoost { _ = try await CtcModels.downloadAndLoad(variant: .ctc110m) }
        }
        logEngine("\(variant.id): first load incl. Core ML compile \(fmt(firstLoadSeconds))s (excluded)")

        let before = physFootprintBytes()
        let (_, loadSeconds) = try await timed {
            let asr = try await AsrModels.downloadAndLoad(version: .v2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(asr)
            self.models = asr
            self.manager = manager
            if wantsBoost {
                let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                self.ctcModels = ctc
                let context = CustomVocabularyContext(terms: vocab.map { CustomVocabularyTerm(text: $0) })
                self.session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctc)
            }
        }
        return LoadStats(loadSeconds: loadSeconds, memoryDeltaBytes: physFootprintBytes() - before)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw EngineError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        if let session, let timings = result.tokenTimings,
           let rescored = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples) {
            return rescored.text
        }
        return result.text
    }

    public func unload() {
        session = nil
        ctcModels = nil
        models = nil
        manager = nil
    }
}
