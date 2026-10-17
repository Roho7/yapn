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
    /// A run of input words the output left out that is neither a filler nor part of a correction.
    case deletedWords([String])
    /// Fewer words survived than any correction explains.
    case tooShort(input: Int, output: Int)
    /// The same words with only case or punctuation changed: not an edit the cleaner is for.
    case cosmeticOnly

    public var description: String {
        switch self {
        case .failed(let error): "cleaner failed: \(error)"
        case .empty: "cleaner returned nothing"
        case .droppedToken(let token): "dropped \(token)"
        case .changedToken(let token): "wrote \(token), which the input does not have"
        case .droppedQuestionMark: "dropped a question mark"
        case .addedWords(let words): "added words: \(words.joined(separator: " "))"
        case .deletedWords(let words): "deleted words outside a correction: \(words.joined(separator: " "))"
        case .tooShort(let input, let output): "kept \(output) of \(input) words"
        case .cosmeticOnly: "changed only case or punctuation"
        }
    }
}

/// Accepts a cleaner's output only if it stays inside the edits the cleaner is allowed to make:
/// delete fillers, lay out a list (dropping its "and"), and, after a correction cue, delete the cue with
/// the words it replaces. Every code token the rules wrote must come through exactly, and a question stays one.
/// The output is aligned word by word against the input. Without a cue it may add nothing and delete only
/// fillers; with one, each deleted run must hold a cue, and at most two joining words may appear.
public func reviewCleanup(input: String, output: String) -> CleanupRejection? {
    if output.allSatisfy(\.isWhitespace) { return input.allSatisfy(\.isWhitespace) ? nil : .empty }

    let inputTokens = Set(codeTokens(in: input)), outputTokens = codeTokens(in: output)
    if let changed = outputTokens.first(where: { !inputTokens.contains($0) }) { return .changedToken(changed) }
    let corrected = hasCorrectionCue(input)
    if !corrected, let dropped = codeTokens(in: input).first(where: { !outputTokens.contains($0) }) {
        return .droppedToken(dropped)
    }
    if output.filter({ $0 == "?" }).count < input.filter({ $0 == "?" }).count { return .droppedQuestionMark }

    let inputWords = contentWords(input), outputWords = contentWords(output)
    let (deletedRuns, inserted) = align(inputWords, outputWords)
    if inserted.count > (corrected ? 2 : 0) { return .addedWords(inserted) }
    let madeList = output.split(separator: "\n").contains { $0.hasPrefix("- ") }
    if let run = deletedRuns.first(where: { !isDeletable($0, corrected: corrected, madeList: madeList) }) {
        return .deletedWords(run)
    }
    if outputWords.count * 4 < inputWords.count { return .tooShort(input: inputWords.count, output: outputWords.count) }
    if deletedRuns.isEmpty, inserted.isEmpty, !madeList, output != input { return .cosmeticOnly }
    return nil
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

private let fillers: Set<String> = ["um", "umm", "uh", "er", "erm", "ah", "hmm"]

/// A deleted run is a filler ("um", "you know"), a list's "and", or, after a cue, a correction that holds the cue.
private func isDeletable(_ run: [String], corrected: Bool, madeList: Bool) -> Bool {
    let text = run.joined(separator: " ")
    if corrected, text.contains(cueInRun) { return true }
    let rest = text.replacing("you know", with: " ").split(separator: " ").map(String.init)
    return rest.allSatisfy { fillers.contains($0) || (madeList && ["and", "or"].contains($0)) }
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

/// The spoken words of the text with Markdown list markers removed, so laying out a list adds no words.
private func contentWords(_ text: String) -> [String] {
    text.split(separator: "\n").flatMap { line in
        spokenWords(String(line.replacing(/^\s*(?:[-*•]|\d+[.)])\s+/, with: "")))
    }
}

/// A longest-common-subsequence alignment: the runs of consecutive input words the output left out,
/// and the output words that match nothing in the input.
private func align(_ input: [String], _ output: [String]) -> (deletedRuns: [[String]], inserted: [String]) {
    let n = input.count, m = output.count
    var common = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            common[i][j] = input[i] == output[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
        }
    }
    var runs: [[String]] = [], run: [String] = [], inserted: [String] = []
    var i = 0, j = 0
    while i < n || j < m {
        if i < n, j < m, input[i] == output[j], common[i][j] == common[i + 1][j + 1] + 1 {
            if !run.isEmpty { runs.append(run); run = [] }
            i += 1; j += 1
        } else if i < n, j == m || common[i + 1][j] >= common[i][j + 1] {
            run.append(input[i])
            i += 1
        } else {
            inserted.append(output[j])
            j += 1
        }
    }
    if !run.isEmpty { runs.append(run) }
    return (runs, inserted)
}
