import Foundation

public enum ModelFamily: String, Codable, Sendable, CaseIterable {
    case whisperTurbo = "whisper-turbo"
    case whisperSmallEn = "whisper-small.en"
    case parakeetV2 = "parakeet-v2"
}

public struct EngineVariant: Hashable, Codable, Sendable, CustomStringConvertible {
    public let model: ModelFamily
    public let biased: Bool

    public init(model: ModelFamily, biased: Bool) {
        self.model = model
        self.biased = biased
    }

    public init?(id: String) {
        let biased = id.hasSuffix("+vocab")
        let base = biased ? String(id.dropLast("+vocab".count)) : id
        guard let model = ModelFamily(rawValue: base) else { return nil }
        self.init(model: model, biased: biased)
    }

    public var id: String { biased ? "\(model.rawValue)+vocab" : model.rawValue }
    public var description: String { id }

    public static let all: [EngineVariant] = ModelFamily.allCases.flatMap {
        [EngineVariant(model: $0, biased: false), EngineVariant(model: $0, biased: true)]
    }
}

public struct LoadStats: Codable, Sendable {
    public let loadSeconds: Double
    public let memoryDeltaBytes: Int64

    public init(loadSeconds: Double, memoryDeltaBytes: Int64) {
        self.loadSeconds = loadSeconds
        self.memoryDeltaBytes = memoryDeltaBytes
    }
}

/// Samples are 16kHz mono Float32. Biasing is fixed per variant, so the vocabulary
/// is handed over at construction: both runtimes need the loaded tokenizer to use it.
public protocol TranscriptionEngine: Actor {
    nonisolated var variant: EngineVariant { get }
    func load() async throws -> LoadStats
    func transcribe(_ samples: [Float]) async throws -> String
    func unload()
}
