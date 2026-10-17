import Testing
@testable import DictationCore

struct HistoryStoreTests {
    private let tone: [Float] = (0..<8000).map { 0.5 * Float(($0 / 20) % 2 == 0 ? 1 : -1) }

    @Test func savedEntriesComeBackCompleteAndOldestFirst() throws {
        let later = historyEntry(atSecond: 5, raw: "second one", pasted: "Second one.", cleanup: .cleaned(text: "Second."))
        let earlier = historyEntry(atSecond: 1, raw: "first one", pasted: "First one.")

        let items = try withTempHistory { history, _ in
            try history.save(later, samples: tone)
            try history.save(earlier, samples: tone)
            try writeTornEntry(in: history, samples: tone)
            return try history.items()
        }

        #expect(items.map(\.entry) == [earlier, later])
        #expect(items.map(\.label) == [nil, nil])
    }

    @Test func styleAndWindowTitleAreKept() throws {
        let entry = HistoryEntry(
            recordedAt: historyEntry(atSecond: 1, raw: "x", pasted: "x").recordedAt, raw: "Git status.", formatted: "git status",
            cleanup: .skipped, pasted: "git status", frontmostApp: "com.apple.Terminal", windowTitle: "zsh", style: .shell,
            timings: historyEntry(atSecond: 1, raw: "x", pasted: "x").timings
        )

        let saved = try withTempHistory { history, _ in
            try history.save(entry, samples: tone)
            return try history.items().map(\.entry)
        }

        #expect(saved == [entry])
    }

    @Test func entriesFromBeforeStylesStillLoad() throws {
        let entry = try decodeLegacyEntry()

        #expect(entry.style == nil)
        #expect(entry.windowTitle == nil)
        #expect(entry.pasted == "git status")
    }

    @Test func cleanupOutcomesAreRecordedWithTheirReason() {
        #expect(HistoryCleanup(.skipped) == .skipped)
        #expect(HistoryCleanup(.accepted("meet Tuesday")) == .cleaned(text: "meet Tuesday"))
        #expect(HistoryCleanup(.rejected(output: "hi", .droppedQuestionMark)) == .fellBack(reason: "\(CleanupRejection.droppedQuestionMark)", llmOutput: "hi"))
    }

    @Test func labellingAddsTheNextClipWithBacktickedTokensAndMarksTheEntry() throws {
        let (first, second, items, clips) = try withTempHistory { history, clips in
            try history.save(historyEntry(atSecond: 1, raw: "run slash grill me", pasted: "run /grill-me"), samples: tone)
            try history.save(historyEntry(atSecond: 2, raw: "meet monday no wait tuesday", pasted: "meet Tuesday"), samples: tone)
            let pending = try history.items()
            let first = try labelClip(pending[0], reference: "run `/grill-me` now", into: clips, history: history)
            let second = try labelClip(pending[1], reference: "meet Tuesday", into: clips, history: history)
            return (first, second, try history.items(), try clips.clips())
        }

        #expect(first == Prompt(id: 1, category: .dictation, written: "run /grill-me now", tokens: ["/grill-me"]))
        #expect(second == Prompt(id: 2, category: .dictation, written: "meet Tuesday", tokens: []))
        #expect(clips.map(\.prompt) == [first, second])
        #expect(items.map(\.label?.clipID) == [1, 2])
    }

    @Test func unbalancedBackticksAreRejectedAndNothingIsSaved() throws {
        let (clipCount, label) = try withTempHistory { history, clips in
            try history.save(historyEntry(atSecond: 1, raw: "x", pasted: "x"), samples: tone)
            let item = try history.items()[0]
            #expect(throws: BacktickError.unbalanced) {
                try labelClip(item, reference: "run `/grill-me now", into: clips, history: history)
            }
            return (try clips.clips().count, try history.items()[0].label)
        }

        #expect(clipCount == 0)
        #expect(label == nil)
    }

    @Test func deleteRemovesTheEntry() throws {
        let remaining = try withTempHistory { history, _ in
            try history.save(historyEntry(atSecond: 1, raw: "keep", pasted: "keep"), samples: tone)
            try history.save(historyEntry(atSecond: 2, raw: "drop", pasted: "drop"), samples: tone)
            try history.delete(try history.items()[1])
            return try history.items().map(\.entry.raw)
        }

        #expect(remaining == ["keep"])
    }
}
