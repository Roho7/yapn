import ArgumentParser
import DictationCore
import Foundation

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record the test clips, one prompt at a time.")

    @Option(help: "Prompt file.") var prompts = "data/prompts.txt"
    @Option(help: "Directory for NNN.wav + NNN.json.") var clips = "data/clips"
    @Flag(help: "Re-record prompts that already have a clip.") var redo = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let all = try PromptFile.parse(String(contentsOfFile: prompts, encoding: .utf8))
        let store = ClipStore(directory: URL(fileURLWithPath: clips))
        var recorded = Set(try store.clips().map(\.prompt.id))
        let pending = all.filter { redo || !recorded.contains($0.id) }

        if pending.isEmpty {
            print("\(recorded.count)/\(all.count) recorded; nothing to do (use --redo to re-record)")
            return
        }
        try await requireMicrophone()
        let flow = CaptureFlow(
            recorder: AudioRecorder(),
            readyHint: "Enter to start recording, s skip, q quit",
            review: true
        )

        for prompt in pending {
            print("\n\(recorded.count)/\(all.count) recorded")
            print("#\(prompt.id) [\(prompt.category.rawValue)]")
            print("  " + highlighted(prompt, ansi: isatty(STDOUT_FILENO) != 0))
            switch try flow.run() {
            case .kept(let take):
                try store.save(prompt, samples: take.samples)
                recorded.insert(prompt.id)
                print("saved \(String(format: "%03d", prompt.id)).wav")
            case .skipped:
                continue
            case .quit:
                print("\n\(recorded.count)/\(all.count) recorded")
                return
            }
        }
        print("\n\(recorded.count)/\(all.count) recorded")
    }
}

func highlighted(_ prompt: Prompt, ansi: Bool) -> String {
    guard ansi else { return prompt.written }
    var result = ""
    var cursor = prompt.written.startIndex
    for token in prompt.tokens {
        guard let range = prompt.written.range(of: token, range: cursor..<prompt.written.endIndex) else { continue }
        result += prompt.written[cursor..<range.lowerBound] + "\u{1B}[1m" + token + "\u{1B}[0m"
        cursor = range.upperBound
    }
    return result + prompt.written[cursor...]
}
