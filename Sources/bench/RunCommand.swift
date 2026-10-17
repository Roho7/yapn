import ArgumentParser
import DictationCore
import Foundation

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run every engine over the recorded clips and write results.json.")

    @Option(help: "all, or comma-separated engine ids.") var engines = "all"
    @Option(help: "Vocabulary file, one term per line.") var vocab = "data/vocab.txt"
    @Option(help: "Directory of recorded clips.") var clips = "data/clips"
    @Option(help: "Output root; a timestamped directory is created inside.") var out = "results"

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let variants = try parseEngines(engines)
        let terms = variants.contains(where: \.biased) ? try loadVocab(path: vocab) : []
        let found = try ClipStore(directory: URL(fileURLWithPath: clips)).clips()
        guard !found.isEmpty else { throw ValidationError("no clips in \(clips); run `bench record` first") }

        let results = try await runBenchmark(variants: variants, clips: found, vocab: terms) { print($0) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let directory = URL(fileURLWithPath: out).appendingPathComponent(formatter.string(from: results.startedAt))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let file = directory.appendingPathComponent("results.json")
        try encoder.encode(results).write(to: file, options: .atomic)

        let summaries = summarize(results)
        print("\n\(results.hardware), \(found.count) clips\n")
        let winner = pickWinner(summaries)
        print(summaryTable(summaries.map { ($0.variant.id + ($0.variant == winner ? " *" : ""), $0) }))
        print(winner.map { "* winner: \($0.id)" } ?? "no engine qualifies (warm RTF p50 * 5.0 must be under 0.5)")
        print("\nresults: \(file.path)")
    }
}

/// One row per labelled summary. The false-insertions column shows "-" when the summary was not checked for them.
func summaryTable(_ rows: [(label: String, summary: EngineSummary)]) -> String {
    func percent(_ value: Double) -> String { String(format: "%.1f", value * 100) }
    func millis(_ value: Double?) -> String { value.map { String(format: "%.0f", $0 * 1000) } ?? "-" }

    let header = ["variant", "lenient %", "strict %", "WER %", "false ins", "p50 ms", "p95 ms", "RTF", "load s", "peak MB"]
    var cells = [header]
    for (label, s) in rows {
        cells.append([
            label,
            percent(s.lenientTokenRate),
            percent(s.strictTokenRate),
            percent(s.wer),
            s.falseInsertions.map(String.init) ?? "-",
            millis(s.warmLatencyP50),
            millis(s.warmLatencyP95),
            s.warmRTFP50.map { String(format: "%.3f", $0) } ?? "-",
            String(format: "%.1f", s.loadSeconds),
            String(format: "%.0f", Double(s.peakMemoryBytes) / 1_048_576),
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
