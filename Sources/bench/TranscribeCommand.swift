import ArgumentParser
import DictationCore
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe one WAV with each engine, cold then warm.")

    @Argument(help: "Path to a WAV file.") var wav: String
    @Option(help: "all, or comma-separated engine ids.") var engines = "all"
    @Option(help: "Vocabulary file, one term per line.") var vocab = "data/vocab.txt"

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let variants = try parseEngines(engines)
        let terms = variants.contains(where: \.biased) ? try loadVocab(path: vocab) : []
        let samples = try loadSamples(from: URL(fileURLWithPath: wav))
        let audioSeconds = Double(samples.count) / targetSampleRate
        print(String(format: "audio: %.2fs, vocab terms: %d", audioSeconds, terms.count))

        for variant in variants {
            let engine = makeEngine(variant, vocab: terms)
            let stats = try await engine.load()
            let (cold, coldPeak) = try await PeakMemorySampler.measure {
                try await timed { try await engine.transcribe(samples) }
            }
            let (warm, warmPeak) = try await PeakMemorySampler.measure {
                try await timed { try await engine.transcribe(samples) }
            }
            await engine.unload()

            print("""

            == \(variant.id)
            load: \(String(format: "%.2fs", stats.loadSeconds)), memory delta: \(megabytes(stats.memoryDeltaBytes))
            cold: \(String(format: "%.3fs", cold.seconds)) (RTF \(String(format: "%.3f", cold.seconds / audioSeconds)))
            warm: \(String(format: "%.3fs", warm.seconds)) (RTF \(String(format: "%.3f", warm.seconds / audioSeconds)))
            peak footprint: \(megabytes(max(coldPeak, warmPeak)))
            cold transcript: \(cold.value.isEmpty ? "<empty>" : cold.value)
            warm transcript: \(warm.value.isEmpty ? "<empty>" : warm.value)
            """)
        }
    }
}

private func megabytes(_ bytes: Int64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
