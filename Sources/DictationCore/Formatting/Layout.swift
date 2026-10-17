/// Where a marker's item sits in its list.
enum ListSlot: Equatable {
    case position(Int)
    /// "finally", "lastly": only closes a list that already has two items, so "First … Finally …" stays prose.
    case last
    case bullet
}

/// Markers form a list only with markers of their own family, so a "number two" inside an ordinal item
/// ("First, fix issue number two") never splits it.
enum ListFamily {
    /// first, secondly, finally
    case ordinal
    /// number one, number two
    case numbered
    /// "one, … two, …": the number word needs its own comma
    case counted
    /// bullet, bullet point, next bullet
    case bullet
    /// dash, only where the spoken-symbol rules would not write "-"
    case dash

    /// "give me a second", "the first one" and "add a bullet point" are not at a clause start, so they never open a list.
    /// A marker that ends a sentence ("priority number one.") has no item after it.
    func accepts(_ marker: MarkerContext, opening: Bool) -> Bool {
        guard !marker.endsSentence else { return false }
        switch self {
        case .ordinal: return marker.startsClause
        case .numbered, .bullet: return !opening || marker.startsClause
        case .counted: return marker.startsClause && [",", ":"].contains(marker.trailing)
        case .dash: return !marker.writtenAsSymbol && (!opening || marker.startsClause)
        }
    }
}

struct MarkerContext {
    let startsClause: Bool
    let trailing: String
    /// The spoken-symbol rules write this "dash" as "-" ("dash c", "force dash with").
    let writtenAsSymbol: Bool

    var endsSentence: Bool { trailing.contains(where: sentenceEnders.contains) }
}

struct ListMarker {
    let phrases: [[String]]
    let family: ListFamily
    let slot: ListSlot
}

private let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
private let ordinalWords = [
    ["first", "firstly"], ["second", "secondly"], ["third", "thirdly"], ["fourth", "fourthly"], ["fifth", "fifthly"],
    ["sixth"], ["seventh"], ["eighth"], ["ninth"], ["tenth"],
]

let listMarkers: [ListMarker] = numberWords.indices.flatMap { index -> [ListMarker] in
    let n = index + 1, spoken = [numberWords[index], String(n)]
    let ordinals = ordinalWords[index].map { [$0] } + (n == 1 ? [["first", "of", "all"]] : [])
    return [
        ListMarker(phrases: ordinals, family: .ordinal, slot: .position(n)),
        ListMarker(phrases: spoken.map { ["number", $0] }, family: .numbered, slot: .position(n)),
        ListMarker(phrases: spoken.map { [$0] }, family: .counted, slot: .position(n)),
    ]
} + [
    ListMarker(phrases: [["finally"], ["lastly"]], family: .ordinal, slot: .last),
    ListMarker(
        phrases: [["bullet"], ["bullet", "point"], ["next", "bullet"], ["next", "bullet", "point"], ["new", "bullet"]],
        family: .bullet,
        slot: .bullet
    ),
    ListMarker(phrases: [["dash"]], family: .dash, slot: .bullet),
]

/// A spoken line break. It fires only at a clause start ("Thanks. New line. Bob"),
/// so "add a new line after the import" stays prose; a stray newline pasted into a shell runs the command.
struct SpokenBreak {
    let phrases: [[String]]
    let text: String
}

let spokenBreaks: [SpokenBreak] = [
    SpokenBreak(phrases: [["new", "line"], ["newline"]], text: "\n"),
    SpokenBreak(phrases: [["new", "paragraph"]], text: "\n\n"),
]

private let sentenceEnders: Set<Character> = [".", "?", "!"]
private let connectives: Set<String> = ["and", "then"]

private let markerTable = listMarkers
    .flatMap { marker in marker.phrases.map { (phrase: $0, marker: marker) } }
    .sorted { $0.phrase.count > $1.phrase.count }
private let breakTable = spokenBreaks
    .flatMap { spokenBreak in spokenBreak.phrases.map { (phrase: $0, text: spokenBreak.text) } }
    .sorted { $0.phrase.count > $1.phrase.count }

/// Lays out the resolved elements as text: spoken breaks split them into lines,
/// and each line's list markers become Markdown lists. With no break or list it is `render`.
/// A line after a break starts a new sentence, so its first word is capitalised.
func layout(_ elements: [Element]) -> String {
    var output = ""
    var line: [Element] = []
    var i = 0
    func flush(_ text: String) {
        let laidOut = layoutLine(line)
        output += (output.isEmpty ? laidOut : capitalisedIfPlain(laidOut)) + text
        line = []
    }
    while i < elements.count {
        if startsClause(after: line.last),
           let hit = breakTable.first(where: { matchPhrase($0.phrase, at: i, in: elements) != nil }) {
            flush(hit.text)
            i += hit.phrase.count
        } else {
            line.append(elements[i])
            i += 1
        }
    }
    flush("")
    return output
}

/// Prose, then a list on its own lines after its lead-in, then a blank line before any prose that follows.
private func layoutLine(_ line: [Element]) -> String {
    var output = ""
    var rest = line
    while let list = firstList(in: rest) {
        let leadIn = Array(rest[..<list.start])
        if let last = leadIn.last {
            let keepsOwnMark = last.trailing.contains("?") || last.trailing.contains("!")
            output += render(leadIn.dropLast() + [last.withTrailing(keepsOwnMark ? last.trailing : ":")]) + "\n"
        }
        output += list.lines.joined(separator: "\n")
        rest = Array(rest[list.end...])
        if !rest.isEmpty { output += "\n\n" }
    }
    return output + render(rest)
}

private struct MarkerHit {
    let range: Range<Int>
    let marker: ListMarker
    let opens: Bool
    let continues: Bool
}

/// The first run of same-family markers in order (1, 2, 3 … or bullet, bullet …) with at least two non-empty items.
/// Each item runs to the next marker; the last one runs to the end of its sentence.
private func firstList(in line: [Element]) -> (start: Int, end: Int, lines: [String])? {
    let hits = markerHits(in: line)
    for (index, opener) in hits.enumerated() where opener.opens {
        var run = [opener]
        for hit in hits[(index + 1)...] {
            if hit.marker.family == opener.marker.family, hit.continues, follows(hit.marker.slot, count: run.count) {
                run.append(hit)
                if hit.marker.slot == .last { break }
            } else if hit.opens {
                break
            }
        }
        guard run.count >= 2 else { continue }
        let last = run[run.count - 1].range.upperBound
        let end = (last..<line.count).first { line[$0].trailing.contains(where: sentenceEnders.contains) }.map { $0 + 1 } ?? line.count
        let items = run.indices.map { k in
            cleanedItem(line[run[k].range.upperBound..<(k + 1 < run.count ? run[k + 1].range.lowerBound : end)])
        }
        guard items.allSatisfy({ !$0.isEmpty }) else { continue }
        let lines = items.enumerated().map { k, item in
            (opener.marker.slot == .bullet ? "- " : "\(k + 1). ") + capitalisedIfPlain(render(item))
        }
        return (opener.range.lowerBound, end, lines)
    }
    return nil
}

private func follows(_ slot: ListSlot, count: Int) -> Bool {
    switch slot {
    case .position(let n): n == count + 1
    case .last: count >= 2
    case .bullet: true
    }
}

private func markerHits(in line: [Element]) -> [MarkerHit] {
    var hits: [MarkerHit] = []
    var i = 0
    while i < line.count {
        guard let hit = markerTable.lazy.compactMap({ entry in
            matchPhrase(entry.phrase, at: i, in: line).map { (length: entry.phrase.count, marker: entry.marker, trailing: $0) }
        }).first else {
            i += 1
            continue
        }
        var writtenAsSymbol = false
        if case .symbol(let rule, _) = line[i] { writtenAsSymbol = rule.glue(neighbours(of: i, in: line)) != nil }
        let context = MarkerContext(
            startsClause: startsClause(after: i > 0 ? line[i - 1] : nil),
            trailing: hit.trailing,
            writtenAsSymbol: writtenAsSymbol
        )
        let marker = hit.marker
        let range = i..<(i + hit.length)
        hits.append(MarkerHit(
            range: range,
            marker: marker,
            opens: [.position(1), .bullet].contains(marker.slot) && marker.family.accepts(context, opening: true),
            continues: marker.family.accepts(context, opening: false)
        ))
        i = range.upperBound
    }
    return hits
}

/// The phrase's words at `index`, spoken bare except the last; returns the punctuation after the last word.
private func matchPhrase(_ phrase: [String], at index: Int, in elements: [Element]) -> String? {
    guard index + phrase.count <= elements.count else { return nil }
    var trailing = ""
    for (offset, expected) in phrase.enumerated() {
        guard let word = elements[index + offset].spokenWord, word.text.lowercased() == expected,
              offset == phrase.count - 1 || word.trailing.isEmpty else { return nil }
        trailing = word.trailing
    }
    return trailing
}

private func startsClause(after previous: Element?) -> Bool {
    guard let previous else { return true }
    if !previous.trailing.isEmpty { return true }
    return previous.spokenWord.map { connectives.contains($0.text.lowercased()) } ?? false
}

/// Drops connectives left before the next marker ("Y, and") and the item's closing comma.
/// A one-sentence item also loses its full stop; a "?" or "!" stays.
private func cleanedItem(_ slice: ArraySlice<Element>) -> [Element] {
    var item = Array(slice)
    while let last = item.last, case .word(let word) = last, word.trailing.isEmpty, connectives.contains(word.text.lowercased()) {
        item.removeLast()
    }
    let isOneSentence = !item.dropLast().contains { $0.trailing.contains(where: sentenceEnders.contains) }
    return trimmed(item, dropping: isOneSentence ? [",", ";", ":", "."] : [",", ";", ":"])
}

private func trimmed(_ elements: [Element], dropping: Set<Character>) -> [Element] {
    guard let last = elements.last else { return elements }
    var trailing = last.trailing
    while let character = trailing.last, dropping.contains(character) { trailing.removeLast() }
    return elements.dropLast() + [last.withTrailing(trailing)]
}

extension Element {
    var trailing: String {
        switch self {
        case .word(let word): word.trailing
        case .name(_, let trailing): trailing
        case .symbol: ""
        }
    }

    /// The single spoken word behind this element, if it is one: a plain word or a one-word symbol ("dash").
    var spokenWord: Word? {
        switch self {
        case .word(let word): word
        case .symbol(_, let spoken) where spoken.count == 1: spoken[0]
        default: nil
        }
    }

    func withTrailing(_ trailing: String) -> Element {
        switch self {
        case .word(let word): .word(Word(text: word.text, trailing: trailing))
        case .name(let name, _): .name(name, trailing: trailing)
        case .symbol: self
        }
    }
}

extension Word {
    var endsSentence: Bool { trailing.contains(where: sentenceEnders.contains) }
}
