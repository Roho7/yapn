import Foundation

public struct CategorySummary: Codable, Sendable, Equatable {
    public let clipCount: Int
    /// Nil when the category has no dev tokens (prose control).
    public let lenientTokenRate: Double?
    public let strictTokenRate: Double?
    public let wer: Double
}

public struct EngineSummary: Codable, Sendable {
    public let variant: EngineVariant
    public let lenientTokenRate: Double
    public let strictTokenRate: Double
    /// Corpus WER: summed edits over summed reference length, not a mean of per-clip rates.
    public let wer: Double
    /// Warm stats exclude the cold first clip and are nil when a run has no warm clip.
    public let warmLatencyP50: Double?
    public let warmLatencyP95: Double?
    public let warmRTFP50: Double?
    public let loadSeconds: Double
    public let peakMemoryBytes: Int64
    public let perCategory: [PromptCategory: CategorySummary]

    public init(
        variant: EngineVariant,
        lenientTokenRate: Double,
        strictTokenRate: Double,
        wer: Double,
        warmLatencyP50: Double?,
        warmLatencyP95: Double?,
        warmRTFP50: Double?,
        loadSeconds: Double,
        peakMemoryBytes: Int64,
        perCategory: [PromptCategory: CategorySummary]
    ) {
        self.variant = variant
        self.lenientTokenRate = lenientTokenRate
        self.strictTokenRate = strictTokenRate
        self.wer = wer
        self.warmLatencyP50 = warmLatencyP50
        self.warmLatencyP95 = warmLatencyP95
        self.warmRTFP50 = warmRTFP50
        self.loadSeconds = loadSeconds
        self.peakMemoryBytes = peakMemoryBytes
        self.perCategory = perCategory
    }
}

public func summarize(_ results: RunResults) -> [EngineSummary] {
    let promptsByID = Dictionary(results.prompts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    return results.runs.map { run in
        let scored: [ClipScore] = run.clips.compactMap { clip in
            promptsByID[clip.promptID].map { score(prompt: $0, transcript: clip.transcript) }
        }
        let warm = run.clips.filter { !$0.isCold }
        let latencies = warm.map(\.latencySeconds)
        let rtfs = warm.map { $0.audioSeconds > 0 ? $0.latencySeconds / $0.audioSeconds : 0 }

        let overall = aggregate(scored)
        return EngineSummary(
            variant: run.variant,
            lenientTokenRate: overall.lenient ?? 0,
            strictTokenRate: overall.strict ?? 0,
            wer: overall.wer,
            warmLatencyP50: percentile(latencies, 0.5),
            warmLatencyP95: percentile(latencies, 0.95),
            warmRTFP50: percentile(rtfs, 0.5),
            loadSeconds: run.load.loadSeconds,
            peakMemoryBytes: run.clips.map(\.peakMemoryBytes).max() ?? 0,
            perCategory: Dictionary(grouping: scored, by: \.category).mapValues { group in
                let summary = aggregate(group)
                return CategorySummary(clipCount: group.count, lenientTokenRate: summary.lenient, strictTokenRate: summary.strict, wer: summary.wer)
            }
        )
    }
}

/// A winner must beat 500ms warm latency on a ~5s clip: warm RTF p50 * 5.0 < 0.5.
/// Among qualifiers: highest lenient token rate, then lower WER, then lower peak memory. Nil if none qualify.
public func pickWinner(_ summaries: [EngineSummary]) -> EngineVariant? {
    summaries
        .filter { ($0.warmRTFP50 ?? .infinity) * winnerReferenceClipSeconds < winnerLatencyLimitSeconds }
        .min { a, b in
            if a.lenientTokenRate != b.lenientTokenRate { return a.lenientTokenRate > b.lenientTokenRate }
            if a.wer != b.wer { return a.wer < b.wer }
            return a.peakMemoryBytes < b.peakMemoryBytes
        }?
        .variant
}

let winnerReferenceClipSeconds = 5.0
let winnerLatencyLimitSeconds = 0.5

private func aggregate(_ scores: [ClipScore]) -> (lenient: Double?, strict: Double?, wer: Double) {
    let tokenCount = scores.reduce(0) { $0 + $1.tokens.count }
    let lenientHits = scores.reduce(0) { $0 + $1.hitCount(.lenient) }
    let strictHits = scores.reduce(0) { $0 + $1.hitCount(.strict) }
    let edits = scores.map(\.words).reduce(WordEdits(substitutions: 0, deletions: 0, insertions: 0, referenceLength: 0), +)
    return (
        tokenCount > 0 ? Double(lenientHits) / Double(tokenCount) : nil,
        tokenCount > 0 ? Double(strictHits) / Double(tokenCount) : nil,
        edits.rate
    )
}

/// Linear interpolation between closest ranks.
func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
}
