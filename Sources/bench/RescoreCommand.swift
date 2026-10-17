import ArgumentParser
import DictationCore
import Foundation

struct Rescore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Score a saved results.json again without re-running the engines, optionally through the formatter and the LLM cleanup."
    )

    @Argument(help: "Results directory holding results.json.") var results: String
    @Flag(name: .customLong("format"), help: "Add a row per engine with every transcript passed through the formatter.") var applyFormat = false
    @Flag(name: .customLong("cleanup"), help: "Also add a row with the formatter's output passed through the on-device LLM cleanup. Implies --format.") var applyCleanup = false
    @Flag(name: .customLong("cleanup-all"), help: "Send every transcript to the cleaner, not only those with a correction cue or a list shape.") var cleanupAll = false
    @Option(help: "Seconds between prewarming the cleaner and each cleanup call, standing in for the hotkey hold during which the app prewarms.") var pause = 1.0
    @Option(help: "Skills directory the formatter resolves names from.") var skillsDir = SkillCatalog.defaultDirectory.path
    @Flag(help: "Print every clip's transcript with its strict misses and false insertions.") var clips = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(
            SavedResults.self,
            from: Data(contentsOf: URL(fileURLWithPath: results).appendingPathComponent("results.json"))
        )
        let raw = RunResults(startedAt: saved.startedAt, hardware: saved.hardware, prompts: saved.prompts, runs: saved.runs.compactMap(\.run))
        let skillsURL = URL(fileURLWithPath: (skillsDir as NSString).expandingTildeInPath)
        let context = FormattingContext(skills: SkillCatalog.load(from: [skillsURL]), slashCommands: SkillCatalog.claudeCodeSlashCommands)
        let vocabulary = context.vocabulary

        var cleaner: (any TranscriptCleaner)?
        if applyCleanup {
            switch makeSystemCleaner() {
            case .ready(let ready):
                cleaner = ready
            case .unavailable(let reason):
                print("cleanup unavailable: \(reason); the +format+cleanup row is skipped\n")
            }
        }

        var stages: [Stage] = applyFormat || applyCleanup ? [.raw, .format] : [.raw]
        var passes: [[ClipPass]] = []
        for run in raw.runs {
            var runPasses: [ClipPass] = []
            for (index, clip) in run.clips.enumerated() {
                let (formatted, formatSeconds) = measure { format(clip.transcript, context: context) }
                var cleaned: CleanupResult?
                if let cleaner {
                    await cleaner.prewarm()
                    if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
                    let result = await cleanup(formatted, with: cleaner, always: cleanupAll)
                    print("[cleanup \(run.variant.id)] \(index + 1)/\(run.clips.count) \(String(format: "%.0f", result.seconds * 1000))ms")
                    cleaned = result
                }
                runPasses.append(ClipPass(clip: clip, formatted: formatted, formatSeconds: formatSeconds, cleanup: cleaned))
            }
            passes.append(runPasses)
        }
        if cleaner != nil { stages.append(.cleanup) }

        let rows = raw.runs.indices.flatMap { run in
            stages.map { stage in
                (raw.runs[run].variant.id + stage.suffix, stageRow(stage, passes: passes[run], prompts: raw.prompts, run: raw.runs[run], vocabulary: vocabulary))
            }
        }

        print("\(raw.hardware), \(raw.prompts.count) prompts; \(context.skills.count) skills from \(skillsURL.path), \(context.slashCommands.count) built-in commands\n")
        print(rescoreTable(rows))
        let skipped = saved.runs.filter { $0.run == nil }.map(\.label)
        if !skipped.isEmpty { print("skipped runs from engines this build does not know: \(skipped.joined(separator: ", "))") }
        print("exact: clips whose words match the reference once case and punctuation are ignored")
        print("worse: clips this stage left with more word edits against the reference than its input had (over-edits)")
        print("false ins: catalog names (\(vocabulary.count)) written in a transcript more often than in its reference")
        print("latency columns are warm clips only, a skipped cleanup counting 0 ms; e2e = transcribe + format + cleanup per clip")

        let known = Set(vocabulary)
        let missing = raw.prompts.flatMap(\.tokens).filter { $0.hasPrefix("/") && !$0.dropFirst().contains("/") && !known.contains($0) }
        print(missing.isEmpty ? "every /name in the prompts is in the catalog" : "not in the catalog: \(missing.joined(separator: ", "))")

        if clips {
            for stage in stages {
                for (run, runPasses) in zip(raw.runs, passes) {
                    printClips(runPasses.map { stage.transcript(of: $0) }, run: run, prompts: raw.prompts, suffix: stage.suffix, vocabulary: vocabulary)
                }
            }
        }
        if cleaner != nil {
            for (run, runPasses) in zip(raw.runs, passes) {
                printCleanupDiffs(runPasses, run: run, prompts: raw.prompts)
            }
        }
    }
}

private enum Stage {
    case raw, format, cleanup

    var suffix: String {
        switch self {
        case .raw: ""
        case .format: " +format"
        case .cleanup: " +format+cleanup"
        }
    }

    /// The stage whose output this one takes as input.
    var input: Stage? {
        switch self {
        case .raw: nil
        case .format: .raw
        case .cleanup: .format
        }
    }

    func transcript(of pass: ClipPass) -> String {
        switch self {
        case .raw: pass.clip.transcript
        case .format: pass.formatted
        case .cleanup: pass.cleanup?.text ?? pass.formatted
        }
    }

    /// Time this stage adds after transcription.
    func addedSeconds(_ pass: ClipPass) -> Double {
        switch self {
        case .raw: 0
        case .format: pass.formatSeconds
        case .cleanup: pass.formatSeconds + (pass.cleanup?.seconds ?? 0)
        }
    }
}

/// One clip through every stage that ran.
private struct ClipPass {
    let clip: ClipResult
    let formatted: String
    let formatSeconds: Double
    let cleanup: CleanupResult?
}

private struct StageRow {
    let summary: EngineSummary
    let hasTokens: Bool
    let exact: Int
    /// Clips this stage made worse than its input; nil for raw, which has no input stage.
    let worse: Int?
    let clipCount: Int
    let transcribeP50: Double?
    /// Nil for the stages without cleanup.
    let cleanupP50: Double?
    let cleanupP95: Double?
    let endToEndP50: Double?
    let endToEndP95: Double?
    let llmCalls: Int?
    let fallbacks: Int?
}

private func stageRow(_ stage: Stage, passes: [ClipPass], prompts: [Prompt], run: EngineRun, vocabulary: [String]) -> StageRow {
    let transcripts = passes.map { stage.transcript(of: $0) }
    let clipResults = zip(passes, transcripts).map { pass, transcript in
        ClipResult(
            promptID: pass.clip.promptID,
            transcript: transcript,
            latencySeconds: pass.clip.latencySeconds,
            audioSeconds: pass.clip.audioSeconds,
            peakMemoryBytes: pass.clip.peakMemoryBytes,
            isCold: pass.clip.isCold
        )
    }
    let results = RunResults(startedAt: .now, hardware: "", prompts: prompts, runs: [EngineRun(variant: run.variant, load: run.load, clips: clipResults)])
    let promptsByID = Dictionary(prompts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let exact = zip(passes, transcripts).filter { pass, transcript in
        promptsByID[pass.clip.promptID].map { spokenWords($0.written) == spokenWords(transcript) } ?? false
    }.count
    let worse = stage.input.map { input in
        worseCount(passes.compactMap { pass in
            promptsByID[pass.clip.promptID].map {
                StageStep(reference: $0.written, input: input.transcript(of: pass), output: stage.transcript(of: pass))
            }
        })
    }
    let warm = passes.filter { !$0.clip.isCold }
    let cleanupSeconds = stage == .cleanup ? warm.compactMap { $0.cleanup?.seconds } : []
    let endToEnd = warm.map { $0.clip.latencySeconds + stage.addedSeconds($0) }
    return StageRow(
        summary: summarize(results, vocabulary: vocabulary)[0],
        hasTokens: prompts.contains { !$0.tokens.isEmpty },
        exact: exact,
        worse: worse,
        clipCount: passes.count,
        transcribeP50: percentile(warm.map(\.clip.latencySeconds), 0.5),
        cleanupP50: percentile(cleanupSeconds, 0.5),
        cleanupP95: percentile(cleanupSeconds, 0.95),
        endToEndP50: percentile(endToEnd, 0.5),
        endToEndP95: percentile(endToEnd, 0.95),
        llmCalls: stage == .cleanup ? passes.filter { $0.cleanup.map { $0.outcome != .skipped } ?? false }.count : nil,
        fallbacks: stage == .cleanup ? passes.filter { if case .rejected = $0.cleanup?.outcome { true } else { false } }.count : nil
    )
}

private func rescoreTable(_ rows: [(label: String, row: StageRow)]) -> String {
    func percent(_ value: Double) -> String { String(format: "%.1f", value * 100) }
    func millis(_ value: Double?) -> String { value.map { String(format: "%.0f", $0 * 1000) } ?? "-" }

    let header = ["variant", "lenient %", "strict %", "WER %", "exact", "worse", "false ins", "transcribe p50", "cleanup p50", "cleanup p95", "e2e p50", "e2e p95", "llm calls", "fallbacks"]
    var cells = [header]
    for (label, row) in rows {
        let s = row.summary
        cells.append([
            label,
            row.hasTokens ? percent(s.lenientTokenRate) : "-",
            row.hasTokens ? percent(s.strictTokenRate) : "-",
            percent(s.wer),
            "\(row.exact)/\(row.clipCount)",
            row.worse.map(String.init) ?? "-",
            s.falseInsertions.map(String.init) ?? "-",
            millis(row.transcribeP50),
            millis(row.cleanupP50),
            millis(row.cleanupP95),
            millis(row.endToEndP50),
            millis(row.endToEndP95),
            row.llmCalls.map(String.init) ?? "-",
            row.fallbacks.map(String.init) ?? "-",
        ])
    }
    let widths = header.indices.map { column in cells.map { $0[column].count }.max() ?? 0 }
    return cells.map { row in
        row.enumerated().map { column, cell in
            let pad = String(repeating: " ", count: widths[column] - cell.count)
            return column == 0 ? cell + pad : pad + cell
        }.joined(separator: "  ")
    }.joined(separator: "\n")
}

/// Every clip's cleanup verdict against the reference. A change that does not lower the clip's word errors
/// is flagged with "!": on a control clip, where there is nothing to correct, that is every change.
private func printCleanupDiffs(_ passes: [ClipPass], run: EngineRun, prompts: [Prompt]) {
    let promptsByID = Dictionary(prompts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func oneLine(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\"" }
    func millis(_ value: Double?) -> String { value.map { String(format: "%.0f", $0 * 1000) } ?? "-" }

    let called = passes.compactMap(\.cleanup).filter { $0.outcome != .skipped }
    print("\n== \(run.variant.id) +format+cleanup, per clip (errors = word edits against the reference, before -> after)")
    print("LLM calls: \(called.count) of \(passes.count); over calls p50 \(millis(percentile(called.map(\.seconds), 0.5))) ms, "
        + "p95 \(millis(percentile(called.map(\.seconds), 0.95))) ms, first \(millis(called.first?.seconds)) ms")
    for pass in passes {
        guard let result = pass.cleanup, let prompt = promptsByID[pass.clip.promptID] else { continue }
        let before = wordEdits(reference: prompt.written, hypothesis: result.input).errors
        let after = wordEdits(reference: prompt.written, hypothesis: result.text).errors
        let head = String(format: "%3d %5.0f ms ", prompt.id, result.seconds * 1000) + prompt.category.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
        switch result.outcome {
        case .skipped:
            print("\(head) skipped   errors \(before)  \(oneLine(result.input))")
        case .rejected(let output, let rejection):
            print("\(head) fallback (\(rejection)) errors \(before)")
            print("      in:  \(oneLine(result.input))")
            if let output { print("      llm: \(oneLine(output))") }
        case .accepted(let output) where output == result.input:
            print("\(head) unchanged errors \(before)  \(oneLine(result.input))")
        case .accepted(let output):
            let verdict = after < before ? "better" : after == before ? "same  !" : "WORSE !"
            print("\(head) \(verdict) errors \(before) -> \(after)")
            print("      in:  \(oneLine(result.input))")
            print("      out: \(oneLine(output))")
        }
    }
}

private func measure<T>(_ body: () -> T) -> (T, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = body()
    return (value, ProcessInfo.processInfo.systemUptime - start)
}

/// Older results hold runs from engines since removed; those are skipped instead of failing the whole file.
private struct SavedResults: Decodable {
    let startedAt: Date
    let hardware: String
    let prompts: [Prompt]
    let runs: [SavedRun]
}

private struct SavedRun: Decodable {
    let run: EngineRun?
    let label: String

    private struct Variant: Decodable {
        let model: String
        let biased: Bool
    }

    private enum CodingKeys: String, CodingKey { case variant }

    init(from decoder: Decoder) throws {
        run = try? EngineRun(from: decoder)
        let variant = try decoder.container(keyedBy: CodingKeys.self).decode(Variant.self, forKey: .variant)
        label = variant.model + (variant.biased ? "+vocab" : "")
    }
}

private func printClips(_ transcripts: [String], run: EngineRun, prompts: [Prompt], suffix: String, vocabulary: [String]) {
    let promptsByID = Dictionary(prompts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    print("\n== \(run.variant.id)\(suffix)")
    for (clip, transcript) in zip(run.clips, transcripts) {
        guard let prompt = promptsByID[clip.promptID] else { continue }
        let clipScore = score(prompt: prompt, transcript: transcript, vocabulary: vocabulary)
        let misses = clipScore.missedTokens(.strict)
        let notes = (misses.isEmpty ? [] : ["miss " + misses.joined(separator: " ")])
            + (clipScore.falseInsertions.isEmpty ? [] : ["FALSE " + clipScore.falseInsertions.joined(separator: " ")])
        print(String(format: "%3d ", prompt.id) + transcript + (notes.isEmpty ? "" : "  [" + notes.joined(separator: "; ") + "]"))
    }
}
