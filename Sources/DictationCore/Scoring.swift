import Foundation

/// The single WER normaliser, applied to reference and hypothesis alike.
/// Symbols become the words a speaker says for them, so `src/lib/auth.ts`
/// and "src slash lib slash auth dot ts" compare equal:
/// `/` -> "slash", `.` between alphanumerics -> "dot", leading `-`/`--` on a word -> "dash"/"dash dash".
/// camelCase, PascalCase, snake_case and kebab-case split into words (acronym runs stay
/// together: `URLSession` -> "url session"). Other punctuation and apostrophes are dropped,
/// everything is lowercased, digits are kept as-is.
public func spokenWords(_ text: String) -> [String] {
    let chars = Array(text)
    var spoken = ""
    var i = 0

    func isWordChar(_ index: Int) -> Bool {
        chars.indices.contains(index) && (chars[index].isLetter || chars[index].isNumber)
    }

    while i < chars.count {
        let c = chars[i]
        switch c {
        case "/":
            spoken += " slash "
        case "." where isWordChar(i - 1) && isWordChar(i + 1):
            spoken += " dot "
        case "-" where i == 0 || chars[i - 1].isWhitespace:
            var end = i
            while end < chars.count, chars[end] == "-" { end += 1 }
            if isWordChar(end) {
                spoken += String(repeating: " dash ", count: end - i)
                i = end
                continue
            }
            spoken += " "
        case "'", "\u{2019}":
            break
        case _ where c.isLetter || c.isNumber:
            spoken.append(c)
        default:
            spoken += " "
        }
        i += 1
    }

    return spoken
        .split(whereSeparator: \.isWhitespace)
        .flatMap { splitCase(String($0)) }
        .map { $0.lowercased() }
}

private func splitCase(_ word: String) -> [String] {
    let chars = Array(word)
    var parts: [String] = []
    var current = ""
    for (i, c) in chars.enumerated() {
        if i > 0, c.isUppercase {
            let previous = chars[i - 1]
            let endsAcronym = previous.isUppercase && i + 1 < chars.count && chars[i + 1].isLowercase
            if previous.isLowercase || previous.isNumber || endsAcronym {
                parts.append(current)
                current = ""
            }
        }
        current.append(c)
    }
    parts.append(current)
    return parts
}

public struct WordEdits: Sendable, Hashable, Codable {
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceLength: Int

    public init(substitutions: Int, deletions: Int, insertions: Int, referenceLength: Int) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceLength = referenceLength
    }

    public var errors: Int { substitutions + deletions + insertions }

    public var rate: Double {
        guard referenceLength > 0 else { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceLength)
    }

    /// Corpus WER is `(a + b + ...).rate`, not the mean of per-clip rates.
    public static func + (lhs: WordEdits, rhs: WordEdits) -> WordEdits {
        WordEdits(
            substitutions: lhs.substitutions + rhs.substitutions,
            deletions: lhs.deletions + rhs.deletions,
            insertions: lhs.insertions + rhs.insertions,
            referenceLength: lhs.referenceLength + rhs.referenceLength
        )
    }
}

public func wordEdits(reference: String, hypothesis: String) -> WordEdits {
    let ref = spokenWords(reference)
    let hyp = spokenWords(hypothesis)

    var distance = Array(repeating: Array(repeating: 0, count: hyp.count + 1), count: ref.count + 1)
    for i in 0...ref.count { distance[i][0] = i }
    for j in 0...hyp.count { distance[0][j] = j }
    for i in stride(from: 1, through: ref.count, by: 1) {
        for j in stride(from: 1, through: hyp.count, by: 1) {
            let substitution = distance[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
            distance[i][j] = min(substitution, distance[i - 1][j] + 1, distance[i][j - 1] + 1)
        }
    }

    var substitutions = 0, deletions = 0, insertions = 0
    var i = ref.count, j = hyp.count
    while i > 0 || j > 0 {
        if i > 0, j > 0, ref[i - 1] == hyp[j - 1], distance[i][j] == distance[i - 1][j - 1] {
            i -= 1; j -= 1
        } else if i > 0, j > 0, distance[i][j] == distance[i - 1][j - 1] + 1 {
            substitutions += 1; i -= 1; j -= 1
        } else if i > 0, distance[i][j] == distance[i - 1][j] + 1 {
            deletions += 1; i -= 1
        } else {
            insertions += 1; j -= 1
        }
    }
    return WordEdits(substitutions: substitutions, deletions: deletions, insertions: insertions, referenceLength: ref.count)
}

public func wordErrorRate(reference: String, hypothesis: String) -> Double {
    wordEdits(reference: reference, hypothesis: hypothesis).rate
}

/// One clip through one stage: the stage turned `input` into `output`, both scored against `reference`.
public struct StageStep: Sendable, Hashable {
    public let reference: String
    public let input: String
    public let output: String

    public init(reference: String, input: String, output: String) {
        self.reference = reference
        self.input = input
        self.output = output
    }

    /// The stage over-edited: its output has more word edits against the reference than its input had.
    public var madeWorse: Bool {
        wordEdits(reference: reference, hypothesis: output).errors > wordEdits(reference: reference, hypothesis: input).errors
    }
}

/// How many clips a stage made worse. A cleanup pass should only remove errors, so this should be 0.
public func worseCount(_ steps: [StageStep]) -> Int {
    steps.filter(\.madeWorse).count
}

public enum TokenMatch: String, Sendable, Hashable, Codable, CaseIterable {
    case lenient
    case strict
}

public func tokenHit(_ token: String, in transcript: String, mode: TokenMatch) -> Bool {
    switch mode {
    case .strict:
        return transcript.contains(token)
    case .lenient:
        let needle = alphanumericsLowercased(token)
        return !needle.isEmpty && alphanumericsLowercased(transcript).contains(needle)
    }
}

private func alphanumericsLowercased(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
}

public struct TokenScore: Sendable, Hashable, Codable {
    public let token: String
    public let matched: Set<TokenMatch>

    public func isHit(_ mode: TokenMatch) -> Bool { matched.contains(mode) }
}

public struct ClipScore: Sendable, Hashable, Codable {
    public let promptID: Int
    public let category: PromptCategory
    public let words: WordEdits
    public let tokens: [TokenScore]
    /// Vocabulary terms written in the transcript but not in the reference. See `falseInsertions`.
    public let falseInsertions: [String]

    public func hitCount(_ mode: TokenMatch) -> Int {
        tokens.filter { $0.isHit(mode) }.count
    }

    public func missedTokens(_ mode: TokenMatch) -> [String] {
        tokens.filter { !$0.isHit(mode) }.map(\.token)
    }
}

public func score(prompt: Prompt, transcript: String, vocabulary: [String] = []) -> ClipScore {
    ClipScore(
        promptID: prompt.id,
        category: prompt.category,
        words: wordEdits(reference: prompt.written, hypothesis: transcript),
        tokens: prompt.tokens.map { token in
            TokenScore(
                token: token,
                matched: Set(TokenMatch.allCases.filter { tokenHit(token, in: transcript, mode: $0) })
            )
        },
        falseInsertions: falseInsertions(vocabulary: vocabulary, reference: prompt.written, hypothesis: transcript)
    )
}

/// Vocabulary terms the hypothesis writes more often than the reference, one entry per extra occurrence,
/// in vocabulary order. The token rates cannot see these: a biased engine that turns "compare" into
/// `/compact` loses nothing on them. A term counts only where it stands alone, so `/review` inside
/// `src/review` and `--force` inside `--force-with-lease` are not occurrences.
public func falseInsertions(vocabulary: [String], reference: String, hypothesis: String) -> [String] {
    var seen: Set<String> = []
    return vocabulary.filter { seen.insert($0).inserted }.flatMap { term in
        let extra = standaloneOccurrences(of: term, in: hypothesis) - standaloneOccurrences(of: term, in: reference)
        return Array(repeating: term, count: max(0, extra))
    }
}

private func standaloneOccurrences(of term: String, in text: String) -> Int {
    guard !term.isEmpty else { return 0 }
    func extendsName(_ c: Character?) -> Bool {
        c.map { $0.isLetter || $0.isNumber || "-_/".contains($0) } ?? false
    }
    var count = 0
    var searchStart = text.startIndex
    while let range = text.range(of: term, range: searchStart..<text.endIndex) {
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        if !extendsName(before), !extendsName(after) { count += 1 }
        searchStart = range.upperBound
    }
    return count
}
