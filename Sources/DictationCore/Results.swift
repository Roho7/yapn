import Foundation

/// Raw measurements only. Scores are derived from these at report time, so a
/// scoring change never needs a re-run.
public struct ClipResult: Codable, Sendable {
    public let promptID: Int
    public let transcript: String
    public let latencySeconds: Double
    public let audioSeconds: Double
    public let peakMemoryBytes: Int64
    public let isCold: Bool

    public init(promptID: Int, transcript: String, latencySeconds: Double, audioSeconds: Double, peakMemoryBytes: Int64, isCold: Bool) {
        self.promptID = promptID
        self.transcript = transcript
        self.latencySeconds = latencySeconds
        self.audioSeconds = audioSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.isCold = isCold
    }
}

public struct EngineRun: Codable, Sendable {
    public let variant: EngineVariant
    public let load: LoadStats
    public let clips: [ClipResult]

    public init(variant: EngineVariant, load: LoadStats, clips: [ClipResult]) {
        self.variant = variant
        self.load = load
        self.clips = clips
    }
}

public struct RunResults: Codable, Sendable {
    public let startedAt: Date
    public let hardware: String
    public let prompts: [Prompt]
    public let runs: [EngineRun]

    public init(startedAt: Date, hardware: String, prompts: [Prompt], runs: [EngineRun]) {
        self.startedAt = startedAt
        self.hardware = hardware
        self.prompts = prompts
        self.runs = runs
    }
}
