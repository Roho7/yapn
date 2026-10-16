import Foundation
@preconcurrency import WhisperKit

public enum EngineError: Error {
    case notLoaded
    case emptyResult
}

func logEngine(_ message: String) {
    FileHandle.standardError.write(Data("[engine] \(message)\n".utf8))
}

public actor WhisperKitEngine: TranscriptionEngine {
    public nonisolated let variant: EngineVariant
    private let modelName: String
    private let vocab: [String]
    private var kit: WhisperKit?
    private var options = DecodingOptions()

    public init(variant: EngineVariant, modelName: String, vocab: [String]) {
        self.variant = variant
        self.modelName = modelName
        self.vocab = vocab
    }

    public func load() async throws -> LoadStats {
        let (folder, downloadSeconds) = try await timed {
            try await WhisperKit.download(variant: modelName)
        }
        logEngine("\(variant.id): download step \(fmt(downloadSeconds))s")

        let (_, firstLoadSeconds) = try await timed {
            let throwaway = try await WhisperKit(makeConfig(folder))
            await throwaway.unloadModels()
        }
        logEngine("\(variant.id): first load incl. Core ML compile \(fmt(firstLoadSeconds))s (excluded)")

        let before = physFootprintBytes()
        let (loaded, loadSeconds) = try await timed { try await WhisperKit(makeConfig(folder)) }
        kit = loaded
        options = try decodingOptions(for: loaded)
        return LoadStats(loadSeconds: loadSeconds, memoryDeltaBytes: physFootprintBytes() - before)
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit else { throw EngineError.notLoaded }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func unload() {
        kit = nil
    }

    private func makeConfig(_ folder: URL) -> WhisperKitConfig {
        WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
    }

    private func decodingOptions(for kit: WhisperKit) throws -> DecodingOptions {
        var options = DecodingOptions(verbose: false, task: .transcribe, language: "en", temperature: 0)
        guard variant.biased, !vocab.isEmpty, let tokenizer = kit.tokenizer else { return options }
        let tokens = WhisperPrompt.tokens(for: vocab, tokenizer: tokenizer)
        options.promptTokens = tokens
        options.usePrefillPrompt = true
        return options
    }
}

enum WhisperPrompt {
    // WhisperKit keeps only the last (maxTokenContext / 2 - 1) prompt tokens.
    static let maxTokens = Constants.maxTokenContext / 2 - 1

    static func tokens(for vocab: [String], tokenizer: any WhisperTokenizer) -> [Int] {
        func encode(_ text: String) -> [Int] {
            tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        var kept: [String] = []
        var used = 0
        for term in vocab {
            let cost = encode(", " + term).count
            if used + cost > maxTokens { break }
            used += cost
            kept.append(term)
        }
        return encode(" " + kept.joined(separator: ", "))
    }
}

func fmt(_ seconds: Double) -> String { String(format: "%.2f", seconds) }
