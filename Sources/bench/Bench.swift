import ArgumentParser

@main
struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Dictation engine benchmark.",
        subcommands: [Transcribe.self, Record.self, Live.self, Run.self, Rescore.self, Label.self]
    )
}
