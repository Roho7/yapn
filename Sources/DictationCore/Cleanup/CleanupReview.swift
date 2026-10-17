/// Why a cleaner's output was thrown away in favour of the rule output.
public enum CleanupRejection: Sendable, Equatable, CustomStringConvertible {
    /// The cleaner threw: the model was unavailable, refused, or hit a guardrail.
    case failed(String)
    case empty
    /// A code token the rules wrote is missing, and no correction cue could explain why.
    case droppedToken(String)
    /// The output holds a code token the input did not: a rule token rewritten, or one made up.
    case changedToken(String)
    /// A question became a statement.
    case droppedQuestionMark
    /// Words the input did not have: it rephrased or answered.
    case addedWords([String])
    /// A run of input words the output left out that is not a crutch, a repeat, a restart, or part of a correction.
    case deletedWords([String])
    /// Fewer words survived than any correction or hesitation explains.
    case tooShort(input: Int, output: Int)
    /// The same words with only case or punctuation changed: not an edit the cleaner is for.
    case cosmeticOnly
    /// The output is mostly capitals where the input was not: the model shouted.
    case shouting
    /// A command came back on more than one line; pasted into a shell, a newline runs it.
    case multiline
    /// A command with an odd number of double quotes, which leaves the shell waiting for more.
    case unbalancedQuotes

    public var description: String {
        switch self {
        case .failed(let error): "cleaner failed: \(error)"
        case .empty: "cleaner returned nothing"
        case .droppedToken(let token): "dropped \(token)"
        case .changedToken(let token): "wrote \(token), which the input does not have"
        case .droppedQuestionMark: "dropped a question mark"
        case .addedWords(let words): "added words: \(words.joined(separator: " "))"
        case .deletedWords(let words): "deleted words that are not a hesitation or a correction: \(words.joined(separator: " "))"
        case .tooShort(let input, let output): "kept \(output) of \(input) words"
        case .shouting: "wrote the text in capitals"
        case .cosmeticOnly: "changed only case or punctuation"
        case .multiline: "wrote more than one line"
        case .unbalancedQuotes: "left a double quote open"
        }
    }
}

/// Accepts a cleaner's output only if it stays inside the edits the cleaner is allowed to make:
/// lay out a list (dropping its "and"), remove hesitation, and, after a correction cue, delete the cue with
/// the words it replaces. Every code token the rules wrote must come through exactly, and a question stays one.
/// The output is aligned word by word against the input, and each run of deleted words must be crutches
/// ("um", "you know", "kind of"), a repeat of the words beside it, a short clause the next one restarts, or,
/// after a cue, hold the cue. Without a cue nothing may be added and at least half the words stay;
/// with one, at most two joining words may appear and a quarter of the words stay.
/// `formal` widens this for the formal style: case and punctuation changes are the point, up to two words may be
/// added, and the deletable crutches include intensifiers ("just", "really") and conjunctions opening a clause ("And so").
public func reviewCleanup(input: String, output: String, formal: Bool = false) -> CleanupRejection? {
    if output.allSatisfy(\.isWhitespace) { return input.allSatisfy(\.isWhitespace) ? nil : .empty }

    if isShouting(output), !isShouting(input) { return .shouting }

    let inputTokens = Set(codeTokens(in: input)), outputTokens = codeTokens(in: output)
    if let changed = outputTokens.first(where: { !inputTokens.contains($0) }) { return .changedToken(changed) }
    let corrected = hasCorrectionCue(input)
    if !corrected, let dropped = codeTokens(in: input).first(where: { !outputTokens.contains($0) }) {
        return .droppedToken(dropped)
    }
    if output.filter({ $0 == "?" }).count < input.filter({ $0 == "?" }).count { return .droppedQuestionMark }

    let inputWords = clauseWords(input), outputWords = clauseWords(output)
    let (deletedRuns, inserted) = align(inputWords.map(\.text), outputWords.map(\.text))
    if inserted.count > (corrected || formal ? 2 : 0) { return .addedWords(inserted) }
    let madeList = output.split(separator: "\n").contains { $0.hasPrefix("- ") }
    if let run = deletedRuns.first(where: { !isDeletable($0, of: inputWords, corrected: corrected, madeList: madeList, formal: formal) }) {
        return .deletedWords(inputWords[run].map(\.text))
    }
    if outputWords.count * (corrected ? 4 : 2) < inputWords.count {
        return .tooShort(input: inputWords.count, output: outputWords.count)
    }
    if !formal, deletedRuns.isEmpty, inserted.isEmpty, !madeList, output != input { return .cosmeticOnly }
    return nil
}

/// Mostly capitals, so a sentence in caps but not an acronym or two in a normal one.
private func isShouting(_ text: String) -> Bool {
    let letters = text.filter(\.isLetter)
    return letters.count >= 6 && letters.filter(\.isUppercase).count * 10 > letters.count * 7
}

/// Words that start a self-correction. "instead" is left out: "from AuthContext instead of props" is not one.
private var correctionCue: Regex<Substring> {
    /\b(?:actually|no,? wait|wait,? no|scratch|i mean|sorry|make that|or rather|correction)\b|\bno,/.ignoresCase()
}

func hasCorrectionCue(_ text: String) -> Bool {
    text.contains(correctionCue)
}

/// The same cues once punctuation is gone, as they appear inside a deleted run of spoken words.
/// Once a cue has fired, a trailing "instead" belongs to the correction: "actually use /code-review instead".
private var cueInRun: Regex<Substring> {
    /\b(?:actually|no|wait|scratch|i mean|sorry|make that|or rather|correction|instead)\b/
}

/// A deleted run is, after a cue, a correction that holds the cue. Otherwise, once its crutches and a list's "and"
/// are taken out, what is left must be nothing, a repeat of the words beside it, or a clause the next one restarts.
private func isDeletable(_ run: Range<Int>, of words: [SpokenWord], corrected: Bool, madeList: Bool, formal: Bool) -> Bool {
    if corrected, words[run].map(\.text).joined(separator: " ").contains(cueInRun) { return true }
    let rest = strippingCrutches(run, of: words, madeList: madeList, formal: formal).rest
    return rest.isEmpty || isRepeat(rest, at: run, in: words) || isRestart(rest, at: run, in: words)
}

/// Tokens a cleaner must copy exactly: backticked spans, and words holding a code symbol
/// (`/grill-me`, `--dry-run`, `-c`, `src/lib/`, `auth.ts`, `max_retry`, `useAuth`).
/// Sentence punctuation around a word is not part of it, so "auth.ts." gives `auth.ts`.
func codeTokens(in text: String) -> [String] {
    let backticked = /`[^`]+`/
    let spans = text.matches(of: backticked).map { String($0.output) }
    let words = text.replacing(backticked, with: " ")
        .split(whereSeparator: \.isWhitespace)
        .map { String($0.drop { "(\"'".contains($0) }.reversed().drop { ",.;:!?)\"'".contains($0) }.reversed()) }
        .filter(isCodeToken)
    return spans + words
}

private func isCodeToken(_ word: String) -> Bool {
    guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
    return word.contains("/") || word.contains("_")
        || word.wholeMatch(of: /-+[A-Za-z].*/) != nil
        || word.contains(/[A-Za-z0-9]\.[A-Za-z]/)
        || word.contains(/[a-z][A-Z]/)
}

/// A longest-common-subsequence alignment: the runs of consecutive input words the output left out, as index ranges
/// into the input, and the output words that match nothing in the input. Where either of two equal words could be
/// the one dropped, the earlier one is, so "she wants, she needs" drops "she wants" and not "wants she".
private func align(_ input: [String], _ output: [String]) -> (deletedRuns: [Range<Int>], inserted: [String]) {
    let n = input.count, m = output.count
    var common = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            common[i][j] = input[i] == output[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
        }
    }
    var runs: [Range<Int>] = [], runStart: Int?, inserted: [String] = []
    var i = 0, j = 0
    while i < n || j < m {
        if i < n, common[i + 1][j] == common[i][j] {
            runStart = runStart ?? i
            i += 1
        } else if i < n, j < m, input[i] == output[j] {
            if let start = runStart { runs.append(start..<i); runStart = nil }
            i += 1; j += 1
        } else {
            inserted.append(output[j])
            j += 1
        }
    }
    if let start = runStart { runs.append(start..<n) }
    return (runs, inserted)
}
