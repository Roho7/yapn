/// How a symbol joins its neighbours: `left` glues it to the word before, `right` to the word after.
struct Glue: Equatable {
    let left: Bool
    let right: Bool
}

/// What a symbol's rule can see around it.
struct Neighbours {
    let previous: Element?
    let next: Element?
    /// The word before is part of a flag already: the second dash in "dash dash dry dash run".
    let continuesFlag: Bool
}

/// One spoken-symbol rule. A rule fires when one of its `phrases` appears as whole words,
/// and `glue` decides from the neighbours whether the symbol is written (nil keeps the spoken words).
/// `names` is the catalog the resolver searches after the symbol, if the symbol introduces a name.
struct SpokenSymbol {
    let phrases: [[String]]
    let symbol: String
    let names: (@Sendable (FormattingContext) -> [String])?
    let glue: @Sendable (Neighbours) -> Glue?
}

/// A literal `/` standing alone is the engine writing the symbol with stray spaces, so it is read as a spoken slash.
let spokenSymbols: [SpokenSymbol] = [
    SpokenSymbol(
        phrases: [["forward", "slash"], ["slash"], ["/"]],
        symbol: "/",
        names: { $0.skills + $0.slashCommands },
        glue: { Glue(left: $0.previous?.isBareWord == true, right: $0.next?.isWord == true) }
    ),
    SpokenSymbol(
        phrases: [["dash", "dash"]],
        symbol: "--",
        names: { $0.flags },
        glue: { $0.next?.isWord == true ? Glue(left: false, right: true) : nil }
    ),
    // Outside a flag a lone "dash" is too often English ("dash off a note"), so it only writes
    // a short flag ("dash c" -> "-c") or continues a flag ("dash dash dry dash run" -> "--dry-run").
    SpokenSymbol(
        phrases: [["dash"], ["hyphen"]],
        symbol: "-",
        names: nil,
        glue: { around in
            guard around.next?.isWord == true else { return nil }
            if around.continuesFlag { return Glue(left: true, right: true) }
            return around.next?.isSingleLetter == true ? Glue(left: false, right: true) : nil
        }
    ),
    SpokenSymbol(
        phrases: [["underscore"]],
        symbol: "_",
        names: nil,
        glue: { around in
            let left = around.previous?.isBareWord == true, right = around.next?.isWord == true
            return left || right ? Glue(left: left, right: right) : nil
        }
    ),
    SpokenSymbol(
        phrases: [["dot"]],
        symbol: ".",
        names: nil,
        glue: { $0.previous?.isBareWord == true && $0.next?.isWord == true ? Glue(left: true, right: true) : nil }
    ),
    SpokenSymbol(
        phrases: [["cd"]],
        symbol: "cd",
        names: nil,
        glue: { $0.previous?.isBareWord == true && $0.next?.isWord == true ? Glue(left: true, right: true) : nil }
    ),
]
