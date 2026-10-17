/// A word as the cleanup gate and guard compare it: `spokenWords` form, and whether it opens a clause
/// (first word of the text, of a line, or after sentence punctuation or a comma).
struct SpokenWord: Equatable {
    let text: String
    let opensClause: Bool
}

/// The spoken words of the text, Markdown list markers removed so laying out a list adds no words.
func clauseWords(_ text: String) -> [SpokenWord] {
    text.split(separator: "\n").flatMap { line in
        String(line.replacing(/^\s*(?:[-*•]|\d+[.)])\s+/, with: ""))
            .split(separator: /[.?!,;:]+(?=\s|$)/)
            .flatMap { clause in
                spokenWords(String(clause)).enumerated().map { SpokenWord(text: $1, opensClause: $0 == 0) }
            }
    }
}

/// Hesitation sounds the formatter normally drops already.
private let fillers: Set<String> = ["um", "umm", "uh", "er", "erm", "ah", "hmm"]

/// Words a speaker leans on while thinking. Each counts only where it cannot be doing grammatical work:
/// "like" after "I" or "looks" is a verb or a comparison, "kind of" after "what" or "a" names a kind,
/// "you know" after "do" asks a question, and "so", "well", "okay" and "oh" only lead a clause.
private struct Crutch {
    let words: [String]
    var notAfter: Set<String> = []
    var leadsClause = false
}

private let determiners: Set<String> = [
    "a", "an", "the", "this", "that", "these", "those", "what", "which", "some", "any", "every", "each",
    "same", "one", "no", "my", "your", "our", "their", "his", "her", "all", "other", "another", "different",
]

/// `spokenWords` drops apostrophes, so "don't" is "dont" and "I'd" is "id".
private let crutches: [Crutch] = [
    Crutch(words: ["you", "know"], notAfter: ["do", "did", "dont", "didnt", "if", "would", "will", "should", "let", "you"]),
    Crutch(words: ["i", "mean"], notAfter: ["what", "if", "thats"]),
    Crutch(words: ["kind", "of"], notAfter: determiners),
    Crutch(words: ["sort", "of"], notAfter: determiners),
    Crutch(words: ["basically"]),
    Crutch(words: ["literally"]),
    Crutch(words: ["like"], notAfter: [
        "i", "you", "we", "they", "he", "she", "id", "youd", "wed", "theyd", "would", "dont", "didnt", "doesnt", "not",
        "look", "looks", "looked", "seem", "seems", "seemed", "sound", "sounds", "feel", "feels", "felt",
        "something", "anything", "nothing", "just", "more", "what",
    ]),
    Crutch(words: ["so"], leadsClause: true),
    Crutch(words: ["well"], leadsClause: true),
    Crutch(words: ["okay"], leadsClause: true),
    Crutch(words: ["ok"], leadsClause: true),
    Crutch(words: ["oh"], leadsClause: true),
]

/// The length of the crutch starting at `index`, if one does and it ends by `end`.
/// `leading` says the word sits at the head of a clause, counting crutches already passed ("okay so").
private func crutchLength(at index: Int, in words: [SpokenWord], end: Int, leading: Bool) -> Int? {
    let before = index > 0 ? words[index - 1].text : nil
    return crutches.first { crutch in
        index + crutch.words.count <= end
            && words[index..<index + crutch.words.count].map(\.text) == crutch.words
            && !(before.map(crutch.notAfter.contains) ?? false)
            && (!crutch.leadsClause || leading)
    }?.words.count
}

/// `words[range]` split into its hesitation words (fillers, crutches and, once a list is laid out, its joining
/// "and" or "or") and the words left.
func strippingCrutches(_ range: Range<Int>, of words: [SpokenWord], madeList: Bool = false) -> (crutches: Int, rest: [String]) {
    var crutchCount = 0
    var rest: [String] = []
    var leading = false
    var i = range.lowerBound
    while i < range.upperBound {
        leading = leading || words[i].opensClause
        if fillers.contains(words[i].text) || (madeList && ["and", "or"].contains(words[i].text)) {
            crutchCount += 1
            i += 1
        } else if let length = crutchLength(at: i, in: words, end: range.upperBound, leading: leading) {
            crutchCount += 1
            i += length
        } else {
            rest.append(words[i].text)
            leading = false
            i += 1
        }
    }
    return (crutchCount, rest)
}

/// Crutches, plus one- or two-word repeats across a comma ("the, the", "to the, to the"), in the text.
/// A bare repeat ("the the") never gets here: `hasRestartSignal` sends it to the cleaner on its own.
func hesitationMarks(_ text: String) -> Int {
    let words = clauseWords(text)
    func repeatsAcrossComma(at i: Int, size: Int) -> Bool {
        guard words[i].opensClause, i >= size, i + size <= words.count else { return false }
        let said = words[i..<(i + size)].map(\.text)
        return words[(i - size)..<i].map(\.text) == said && said.allSatisfy { isPlainWord($0) && !repeatExemptWords.contains($0) }
    }
    let commaRepeats = words.indices.filter { i in repeatsAcrossComma(at: i, size: 1) || repeatsAcrossComma(at: i, size: 2) }.count
    return strippingCrutches(words.indices, of: words).crutches + commaRepeats
}

/// A word whose double is often grammatical: "They had had enough", "I know that that is true".
private let grammaticalDoubles: Set<String> = ["had", "that"]

/// The dropped words (at least one) are one or more copies of the words right after or right before them:
/// "we should, we should add", "the, the, the file". A one-word repeat is not taken when the double can be
/// real English ("had had", "that that", "what it is is") or is said for emphasis ("very very").
func isRepeat(_ dropped: [String], at range: Range<Int>, in words: [SpokenWord]) -> Bool {
    (1...dropped.count).contains { size in
        guard dropped.count % size == 0 else { return false }
        let unit = Array(dropped[0..<size])
        guard stride(from: 0, to: dropped.count, by: size).allSatisfy({ Array(dropped[$0..<$0 + size]) == unit }) else { return false }
        if size == 1 {
            let word = unit[0]
            if grammaticalDoubles.contains(word) || repeatExemptWords.contains(word) { return false }
            let lead = words[max(0, range.lowerBound - 5)..<range.lowerBound].map(\.text)
            if ["is", "was"].contains(word), lead.contains("what") { return false }
        }
        let after = range.upperBound + size <= words.count ? words[range.upperBound..<range.upperBound + size].map(\.text) : nil
        let before = range.lowerBound >= size ? words[range.lowerBound - size..<range.lowerBound].map(\.text) : nil
        return after == unit || before == unit
    }
}

/// The dropped words are a clause the speaker abandoned for the one right after it, which starts the same way:
/// "she wants, she needs the report". Two or three words need only the first word shared, unless it is an
/// article ("the parser, the lexer" is a list); four to six also need the last word at the same place
/// ("I want to, I need to refactor").
func isRestart(_ dropped: [String], at range: Range<Int>, in words: [SpokenWord]) -> Bool {
    let next = words[range.upperBound...].map(\.text)
    guard (2...6).contains(dropped.count), dropped.first == next.first else { return false }
    let sameEnd = next.count >= dropped.count && dropped.last == next[dropped.count - 1]
    return sameEnd || (dropped.count <= 3 && !determiners.contains(dropped[0]))
}
