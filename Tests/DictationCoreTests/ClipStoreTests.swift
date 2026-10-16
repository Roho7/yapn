import Testing
@testable import DictationCore

struct ClipStoreTests {
    private func tone(count: Int) -> [Float] {
        (0..<count).map { 0.5 * Float(($0 / 20) % 2 == 0 ? 1 : -1) }
    }

    @Test func saveThenClipsRoundTripsPromptAndSamples() throws {
        let prompt = Prompt(id: 7, category: .flag, written: "add a --dry-run flag", tokens: ["--dry-run"])
        let samples = tone(count: 8000)

        let clips = try withTempClipStore { store in
            try store.save(prompt, samples: samples)
            return try store.clips().map { ($0.prompt, (try? loadSamples(from: $0.audioURL)) ?? []) }
        }

        #expect(clips.count == 1)
        #expect(clips[0].0 == prompt)
        #expect(abs(clips[0].1.count - 8000) <= 1)
        #expect(abs(clips[0].1[10] - 0.5) < 0.001)
        #expect(abs(clips[0].1[30] - -0.5) < 0.001)
    }

    @Test func clipsAreSortedByIdAndRerecordingOverwrites() throws {
        let second = Prompt(id: 2, category: .path, written: "open a/b.ts", tokens: ["a/b.ts"])
        let first = Prompt(id: 1, category: .prose, written: "hello", tokens: [])

        let ids = try withTempClipStore { store in
            try store.save(second, samples: tone(count: 1600))
            try store.save(first, samples: tone(count: 1600))
            try store.save(first, samples: tone(count: 3200))
            let clips = try store.clips()
            return (clips.map(\.prompt.id), try loadSamples(from: clips[0].audioURL).count)
        }

        #expect(ids.0 == [1, 2])
        #expect(abs(ids.1 - 3200) <= 1)
    }

    @Test func emptyOrMissingDirectoryHasNoClips() throws {
        let count = try withTempClipStore { try $0.clips().count }
        #expect(count == 0)
    }
}
