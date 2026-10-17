import Testing
@testable import DictationCore

private let plain = EngineVariant(model: .parakeetV2, biased: false)
private let biased = EngineVariant(model: .parakeetV2, biased: true)

private let prompts = [
    Prompt(id: 1, category: .path, written: "open src/lib/auth.ts", tokens: ["src/lib/auth.ts"]),
    Prompt(id: 2, category: .flag, written: "add --dry-run flag", tokens: ["--dry-run"]),
    Prompt(id: 3, category: .prose, written: "hello there", tokens: []),
    Prompt(id: 4, category: .path, written: "edit app/main.ts", tokens: ["app/main.ts"]),
    Prompt(id: 5, category: .flag, written: "run with --verbose", tokens: ["--verbose"]),
]

private func clip(_ id: Int, _ transcript: String, latency: Double, peak: Int64, cold: Bool = false) -> ClipResult {
    ClipResult(promptID: id, transcript: transcript, latencySeconds: latency, audioSeconds: 2.0, peakMemoryBytes: peak, isCold: cold)
}

private func handBuiltResults() -> RunResults {
    let clips = [
        clip(1, "open src/lib/auth.ts", latency: 2.0, peak: 5_000, cold: true),
        clip(2, "add dry run flag", latency: 0.1, peak: 3_000),
        clip(3, "hello there", latency: 0.2, peak: 2_000),
        clip(4, "edit app main dot ts", latency: 0.3, peak: 2_000),
        clip(5, "run with verbose", latency: 0.4, peak: 2_000),
    ]
    return RunResults(
        startedAt: .distantPast,
        hardware: "test",
        prompts: prompts,
        runs: [EngineRun(variant: plain, load: LoadStats(loadSeconds: 1.5, memoryDeltaBytes: 100), clips: clips)]
    )
}

struct SummarizeTests {
    @Test func warmStatsExcludeTheColdClip() throws {
        let summary = try #require(summarize(handBuiltResults()).first)
        #expect(summary.warmLatencyP50 == 0.25)
        #expect(abs(try #require(summary.warmLatencyP95) - 0.385) < 1e-9)
        #expect(abs(try #require(summary.warmRTFP50) - 0.125) < 1e-9)
        #expect(summary.loadSeconds == 1.5)
        #expect(summary.peakMemoryBytes == 5_000)
    }

    @Test func tokenRatesAndCorpusWER() throws {
        let summary = try #require(summarize(handBuiltResults()).first)
        #expect(summary.lenientTokenRate == 0.75)
        #expect(summary.strictTokenRate == 0.25)
        #expect(abs(summary.wer - 5.0 / 27.0) < 1e-9)
    }

    @Test func falseInsertionsAreSummedOnlyWhenAVocabularyIsGiven() throws {
        let checked = try #require(summarize(handBuiltResults(), vocabulary: ["--verbose", "/lib"]).first)
        #expect(checked.falseInsertions == 0)
        let unchecked = try #require(summarize(handBuiltResults()).first)
        #expect(unchecked.falseInsertions == nil)

        var results = handBuiltResults()
        let run = results.runs[0]
        results = RunResults(startedAt: results.startedAt, hardware: results.hardware, prompts: results.prompts, runs: [
            EngineRun(variant: run.variant, load: run.load, clips: run.clips + [clip(3, "hello /compact there /compact", latency: 0.1, peak: 1)]),
        ])
        #expect(try #require(summarize(results, vocabulary: ["/compact"]).first).falseInsertions == 2)
    }

    @Test func perCategoryRates() throws {
        let summary = try #require(summarize(handBuiltResults()).first)
        #expect(summary.perCategory[.path] == CategorySummary(clipCount: 2, lenientTokenRate: 0.5, strictTokenRate: 0.5, wer: 1.0 / 14.0))
        #expect(summary.perCategory[.flag] == CategorySummary(clipCount: 2, lenientTokenRate: 1.0, strictTokenRate: 0.0, wer: 4.0 / 11.0))
        #expect(summary.perCategory[.prose] == CategorySummary(clipCount: 1, lenientTokenRate: nil, strictTokenRate: nil, wer: 0))
    }
}

private func summary(_ variant: EngineVariant, lenient: Double, wer: Double = 0.1, rtf: Double?, peak: Int64 = 1_000) -> EngineSummary {
    EngineSummary(
        variant: variant, lenientTokenRate: lenient, strictTokenRate: 0, wer: wer,
        warmLatencyP50: nil, warmLatencyP95: nil, warmRTFP50: rtf,
        loadSeconds: 1, peakMemoryBytes: peak, perCategory: [:]
    )
}

struct PickWinnerTests {
    @Test func accurateButSlowIsDisqualified() {
        let winner = pickWinner([
            summary(plain, lenient: 0.6, rtf: 0.02),
            summary(biased, lenient: 0.95, rtf: 0.12),
        ])
        #expect(winner == plain)
    }

    @Test func moreAccurateWinsWhenBothAreFastEnough() {
        let winner = pickWinner([
            summary(plain, lenient: 0.6, rtf: 0.02),
            summary(biased, lenient: 0.9, rtf: 0.08),
        ])
        #expect(winner == biased)
    }

    @Test func lenientTieBreaksOnLowerWER() {
        let winner = pickWinner([
            summary(plain, lenient: 0.9, wer: 0.10, rtf: 0.05),
            summary(biased, lenient: 0.9, wer: 0.05, rtf: 0.05),
        ])
        #expect(winner == biased)
    }

    @Test func werTieBreaksOnLowerPeakMemory() {
        let winner = pickWinner([
            summary(plain, lenient: 0.9, wer: 0.05, rtf: 0.05, peak: 4_000),
            summary(biased, lenient: 0.9, wer: 0.05, rtf: 0.05, peak: 2_000),
        ])
        #expect(winner == biased)
    }

    @Test func nilWhenNoEngineIsFastEnough() {
        #expect(pickWinner([summary(plain, lenient: 0.9, rtf: 0.2), summary(biased, lenient: 0.8, rtf: nil)]) == nil)
        #expect(pickWinner([]) == nil)
    }
}
