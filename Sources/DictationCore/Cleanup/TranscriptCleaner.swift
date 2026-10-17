/// A second pass over the formatted transcript for what rules cannot do: self-corrections
/// ("Monday, no wait, Tuesday") and lists spoken without markers.
public protocol TranscriptCleaner: Sendable {
    func clean(_ text: String) async throws -> String
    /// Gets ready for the next `clean`. The on-device model's warm state fades after 5 to 10 s idle and takes
    /// ~700 ms to rebuild, so callers prewarm when a dictation starts, while the user is still speaking.
    func prewarm() async
}

extension TranscriptCleaner {
    public func prewarm() async {}
}

public enum CleanupOutcome: Sendable, Equatable {
    /// No correction cue, restart or list shape, so the cleaner was not asked.
    case skipped
    /// The cleaner's text, which passed `reviewCleanup`.
    case accepted(String)
    /// The cleaner's text (nil when it threw) and why the rule output is kept instead.
    case rejected(output: String?, CleanupRejection)
}

/// One cleanup pass over one formatted transcript.
public struct CleanupResult: Sendable, Equatable {
    /// The rule output the cleaner was given.
    public let input: String
    public let outcome: CleanupOutcome
    public let seconds: Double

    /// What to insert.
    public var text: String {
        if case .accepted(let output) = outcome { output } else { input }
    }

    public init(input: String, outcome: CleanupOutcome, seconds: Double) {
        self.input = input
        self.outcome = outcome
        self.seconds = seconds
    }
}

/// Runs `cleaner` on the rule output and keeps its answer only if `reviewCleanup` accepts it.
/// Text with no correction cue, restart signal or list shape skips the cleaner, unless `always` is set.
/// It never throws: every failure falls back to `formatted`.
public func cleanup(_ formatted: String, with cleaner: any TranscriptCleaner, always: Bool = false) async -> CleanupResult {
    guard always || mayNeedCleanup(formatted) else { return CleanupResult(input: formatted, outcome: .skipped, seconds: 0) }
    let clock = ContinuousClock()
    let start = clock.now
    let outcome: CleanupOutcome
    do {
        let cleaned = try await cleaner.clean(formatted)
        outcome = reviewCleanup(input: formatted, output: cleaned).map { .rejected(output: cleaned, $0) } ?? .accepted(cleaned)
    } catch {
        outcome = .rejected(output: nil, .failed("\(error)"))
    }
    let elapsed = start.duration(to: clock.now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return CleanupResult(input: formatted, outcome: outcome, seconds: seconds)
}

/// The cleaner can only help a correction, a restart, or an unmarked list. A list needs separators: two commas,
/// or a comma and an "and" ("milk, eggs and bread"). Text the rules already laid out on lines is left alone.
/// Every check is a string check, so a transcript that needs nothing never waits for the model.
func mayNeedCleanup(_ text: String) -> Bool {
    if hasCorrectionCue(text) || hasRestartSignal(text) { return true }
    guard !text.contains("\n") else { return false }
    let commas = text.filter { $0 == "," }.count
    return commas >= 2 || (commas == 1 && text.contains(/\band\b/.ignoresCase()))
}

/// A restart the rules cannot repair without risking real prose. Three shapes:
/// a word the rules kept said twice ("that that", "is is"), a two-word phrase said twice ("I think I think"),
/// and a short phrase abandoned and begun again ("I want to, I need to").
/// The last is also "what it doesn't do is that", the speaker starting "what X is" and swerving to "that".
/// It also fires on real prose ("what I need is that you review it"), costing one wasted call, never a wrong edit.
func hasRestartSignal(_ text: String) -> Bool {
    let words = lex(text)
    let key = { (word: Word) in word.text.lowercased() }
    func repeatable(_ word: Word) -> Bool { isPlainWord(word.text) && !repeatExemptWords.contains(key(word)) }

    for (i, word) in words.enumerated() where repeatable(word) && word.trailing.isEmpty && i + 1 < words.count {
        let next = words[i + 1]
        if key(word) == key(next) { return true }
        if i + 3 < words.count, repeatable(next), next.trailing.isEmpty,
           [key(word), key(next)] == [key(words[i + 2]), key(words[i + 3])] { return true }
    }
    return hasCommaRestart(words) || text.contains(pseudoCleftSwerve)
}

private var pseudoCleftSwerve: Regex<Substring> { /\bwhat(?:\s+[\w'\u{2019}]+){1,5}?\s+(?:is|was)\s+that\b/.ignoresCase() }

/// "I want to, I need to": a clause of two to four words ended by a comma, then a clause that opens with the same
/// word and ends its first as many words with the same word. Different tails ("In the end, in the morning") are parallel
/// phrasing, not a restart.
private func hasCommaRestart(_ words: [Word]) -> Bool {
    var clauses: [(words: [String], endsWithComma: Bool)] = []
    var current: [String] = []
    for word in words {
        current.append(word.text.lowercased())
        if !word.trailing.isEmpty {
            clauses.append((current, word.trailing.hasPrefix(",")))
            current = []
        }
    }
    clauses.append((current, false))
    return zip(clauses, clauses.dropFirst()).contains { first, second in
        let size = first.words.count
        guard first.endsWithComma, (2...4).contains(size), second.words.count >= size else { return false }
        return first.words.first == second.words.first && first.words.last == second.words[size - 1]
            && !first.words.contains(where: repeatExemptWords.contains)
    }
}
