import Testing
@testable import DictationCore

private let none = FormattingContext()

struct ShellRuleTests {
    @Test(arguments: [
        ("Git status.", "git status"),
        ("Run the tests with the verbose flag.", "run the tests --verbose"),
        ("npm test, verbose flag", "npm test --verbose"),
        ("Deploy with the dry run flag.", "deploy --dry-run"),
        ("git push force with lease flag", "git push --force-with-lease"),
        ("Git log, flag oneline.", "git log --oneline"),
        ("ls short flag l", "ls -l"),
        ("grep, long flag ignore case, todo", "grep --ignore-case todo"),
        ("Python script dot py, argument input dot txt.", "python script.py input.txt"),
        ("cargo build, pass the release flag", "cargo build --release"),
        ("tar dash x f archive dot tar", "tar -x f archive.tar"),
        ("Docker compose up dash d.", "docker compose up -d"),
        ("git commit with message fix login bug.", "git commit with message fix login bug"),
        ("Echo hello. New line. World", "echo hello new line world"),
        ("README dot md", "README.md"),
        ("Get status.", "git status"),
        ("NPM test.", "npm test"),
        ("Docker Compose up, dash D.", "docker compose up -d"),
        ("git branch dash capital D old", "git branch -D old"),
        ("C D S R C slash components", "cd src/components"),
        ("L S, dash L A", "ls -l a"),
    ])
    func spokenCommandBecomesACommandLine(_ spoken: String, _ command: String) {
        #expect(format(spoken, context: none, style: .shell) == command)
    }

    @Test func aBareFlagWordStays() {
        #expect(format("the flag", context: none, style: .shell) == "the flag")
    }
}

struct FormalRuleTests {
    @Test(arguments: [
        ("thanks for the intro", "Thanks for the intro."),
        ("great post. totally agree", "Great post. Totally agree."),
        ("Is this still open?", "Is this still open?"),
        ("see src/lib/auth.ts", "See src/lib/auth.ts."),
    ])
    func sentencesAreCapitalisedAndClosed(_ spoken: String, _ written: String) {
        #expect(format(spoken, context: none, style: .formal) == written)
    }

    @Test func defaultAndClaudeCodeWriteTheSameText() {
        let raw = "um so run slash simplify on the parser, the lexer and the tests"
        let context = FormattingContext(slashCommands: ["simplify"])
        #expect(format(raw, context: context, style: .claudeCode) == format(raw, context: context))
        #expect(format(raw, context: context) == "so run /simplify on the parser, the lexer and the tests")
    }
}

struct FormalCrutchRuleTests {
    @Test(arguments: [
        ("And so basically, we're looking for a designer.", "We're looking for a designer."),
        ("But like the main lesson is to listen.", "The main lesson is to listen."),
        ("I'm, like, super excited to share this.", "I'm super excited to share this."),
        ("Honestly, this was kind of the best talk.", "This was the best talk."),
        ("We shipped it and, you know, the results are great.", "We shipped it and the results are great."),
        ("So I wanted to say thanks.", "I wanted to say thanks."),
    ])
    func crutchesAndLeadingConjunctionsGo(_ spoken: String, _ written: String) {
        #expect(format(spoken, context: none, style: .formal) == written)
    }

    @Test(arguments: [
        "I like how you framed the problem.",
        "We use tools like Figma and Linear.",
        "What kind of tools does your team use?",
        "Do you know the answer?",
        "You know the drill.",
        "We are hiring in London and Berlin.",
        "It feels like home.",
    ])
    func meaningfulUsesStay(_ text: String) {
        #expect(format(text, context: none, style: .formal) == text)
    }
}
