import ArgumentParser
import DictationCore
import Foundation

struct Live: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Dictate into the microphone and compare engines side by side.")

    @Option(help: "all, or comma-separated engine ids.") var engines = "all"
    @Option(help: "Vocabulary file, one term per line.") var vocab = "data/vocab.txt"
    @Option(help: "Save each take as NNN.wav in this directory.") var save: String?

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let variants = try parseEngines(engines)
        let terms = variants.contains(where: \.biased) ? try loadVocab(path: vocab) : []
        try await requireMicrophone()

        var loaded: [any TranscriptionEngine] = []
        for variant in variants {
            let engine = makeEngine(variant, vocab: terms)
            let stats = try await engine.load()
            print("loaded \(variant.id) in \(String(format: "%.1fs", stats.loadSeconds))")
            loaded.append(engine)
        }
        tcflush(STDIN_FILENO, TCIFLUSH)
        print("ready")

        let width = (variants.map(\.id.count).max() ?? 0) + 2
        let flow = CaptureFlow(
            recorder: AudioRecorder(),
            readyHint: "\nPress Enter to talk, Enter to stop (q to quit)",
            review: false
        )
        while case .kept(let take) = try flow.run() {
            if let save {
                let url = try nextClipURL(in: URL(fileURLWithPath: save))
                try writeWAV(take.samples, to: url)
                print("saved \(url.path)")
            }
            for engine in loaded {
                let id = engine.variant.id.padding(toLength: width, withPad: " ", startingAt: 0)
                do {
                    let (text, seconds) = try await timed { try await engine.transcribe(take.samples) }
                    let rtf = take.seconds > 0 ? seconds / take.seconds : 0
                    print(id + String(format: "%6.0f ms  RTF %.3f  ", seconds * 1000, rtf) + (text.isEmpty ? "<empty>" : text))
                } catch {
                    print(id + "error: \(error)")
                }
            }
        }
        for engine in loaded { await engine.unload() }
    }
}

private func nextClipURL(in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let highest = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }
        .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
        .max() ?? 0
    return directory.appendingPathComponent(String(format: "%03d.wav", highest + 1))
}
