/// A second pass over the formatted transcript for what rules cannot do: self-corrections
/// ("Monday, no wait, Tuesday"), hesitant restarts ("we should, we should, you know, add"), and lists spoken without markers.
public protocol TranscriptCleaner: Sendable {
    /// `instructions` is the style's system prompt, `cleanupPolicy(for:).instructions`.
    func clean(_ text: String, instructions: String) async throws -> String
    /// Gets ready for the next `clean` with these instructions. The on-device model's warm state fades after 5 to 10 s
    /// idle and takes ~700 ms to rebuild, so callers prewarm when a dictation starts, while the user is still speaking.
    func prewarm(instructions: String) async
}

extension TranscriptCleaner {
    public func prewarm(instructions: String) async {}
}

public enum CleanupOutcome: Sendable, Equatable {
    /// No correction cue, restart, hesitation or list shape, so the cleaner was not asked.
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

/// Runs `cleaner` on the rule output and keeps its answer only if the style's review accepts it.
/// Text the style's gate says needs nothing skips the cleaner, unless `always` is set.
/// It never throws: every failure falls back to `formatted`.
public func cleanup(_ formatted: String, with cleaner: any TranscriptCleaner, style: DictationStyle = .default, always: Bool = false) async -> CleanupResult {
    let policy = cleanupPolicy(for: style)
    guard always || policy.mayNeedCleanup(formatted) else { return CleanupResult(input: formatted, outcome: .skipped, seconds: 0) }
    let clock = ContinuousClock()
    let start = clock.now
    let outcome: CleanupOutcome
    do {
        let cleaned = policy.normalize(try await cleaner.clean(formatted, instructions: policy.instructions))
        outcome = policy.review(formatted, cleaned).map { .rejected(output: cleaned, $0) } ?? .accepted(cleaned)
    } catch {
        outcome = .rejected(output: nil, .failed("\(error)"))
    }
    let elapsed = start.duration(to: clock.now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return CleanupResult(input: formatted, outcome: outcome, seconds: seconds)
}

/// The cleaner can only help a correction, a restart, heavy hesitation, or an unmarked list. Heavy means two or more
/// crutches or comma-split repeats ("so, like, the, the build"): one "so" or "you know" is how people talk.
/// A list needs separators: two commas, or a comma and an "and" ("milk, eggs and bread").
/// Text the rules already laid out on lines is left alone.
/// Every check is a string check, so a transcript that needs nothing never waits for the model.
func mayNeedCleanup(_ text: String) -> Bool {
    if hasCorrectionCue(text) || hasRestartSignal(text) || hesitationMarks(text) >= 2 { return true }
    guard !text.contains("\n") else { return false }
    let commas = text.filter { $0 == "," }.count
    return commas >= 2 || (commas == 1 && text.contains(/\band\b/.ignoresCase()))
}

/// A restart the rules cannot repair without risking real prose. Two shapes:
/// a phrase of one to four words the rules kept said twice ("that that", "I think I think", "I was going to I was going to"),
/// and a short phrase abandoned and begun again ("I want to, I need to").
/// The last is also "what it doesn't do is that", the speaker starting "what X is" and swerving to "that".
/// It also fires on real prose ("what I need is that you review it"), costing one wasted call, never a wrong edit.
func hasRestartSignal(_ text: String) -> Bool {
    let words = lex(text)
    let key = { (word: Word) in word.text.lowercased() }
    func bareRepeatable(_ word: Word) -> Bool {
        word.trailing.isEmpty && isPlainWord(word.text) && !repeatExemptWords.contains(key(word))
    }
    let saidTwice = words.indices.contains { i in
        (1...4).contains { size in
            i + 2 * size <= words.count && words[i..<i + size].allSatisfy(bareRepeatable)
                && words[i..<i + size].map(key) == words[i + size..<i + 2 * size].map(key)
        }
    }
    return saidTwice || hasCommaRestart(words) || text.contains(pseudoCleftSwerve)
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
