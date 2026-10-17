import Testing
@testable import DictationCore

private let none = FormattingContext()

struct SpokenSymbolTests {
    @Test func spokenPathBecomesAPath() {
        #expect(format("open src slash lib slash auth dot ts now", context: none) == "open src/lib/auth.ts now")
        #expect(format("open src forward slash lib", context: none) == "open src/lib")
    }

    @Test func engineWritingSlashAndTheWordKeepsOneSlash() {
        #expect(format("Open src/slash lib/slash auth.ts and check", context: none) == "Open src/lib/auth.ts and check")
    }

    @Test func engineWrittenTrailingSlashKeepsItsSpace() {
        #expect(format("Move it into src/components/layout/ and fix the imports.", context: none) == "Move it into src/components/layout/ and fix the imports.")
    }

    @Test func underscoreJoinsWords() {
        #expect(format("add test underscore scoring dot py", context: none) == "add test_scoring.py")
    }

    @Test func dashDashStartsAFlagAndSpokenDashesContinueIt() {
        #expect(format("run with dash dash verbose", context: none) == "run with --verbose")
        #expect(format("push with dash dash force dash with dash lease now", context: none) == "push with --force-with-lease now")
    }

    @Test func dashBeforeOneLetterIsAShortFlag() {
        #expect(format("build with dash c release", context: none) == "build with -c release")
    }

    @Test func multiWordFlagStaysUnjoinedWithoutAName() {
        #expect(format("add dash dash dry run", context: none) == "add --dry run")
    }

    @Test func dotNeedsAWordOnBothSides() {
        #expect(format("connect the last dot", context: none) == "connect the last dot")
        #expect(format("put a dot, then stop", context: none) == "put a dot, then stop")
    }

    @Test func loneDashOutsideAFlagStaysAWord() {
        #expect(format("I will dash off a note", context: none) == "I will dash off a note")
    }
}

struct ResolverTests {
    private let context = FormattingContext(
        skills: ["grill-me", "grill-with-docs", "poteto-mode"],
        slashCommands: ["code-review", "review", "compact", "init"],
        flags: ["dry-run"]
    )

    @Test func resolvesSpokenSkillName() {
        #expect(format("run slash grill me on this", context: context) == "run /grill-me on this")
    }

    @Test func prefersTheLongestName() {
        #expect(format("try slash grill with docs now", context: context) == "try /grill-with-docs now")
        #expect(format("Run slash code review on this branch.", context: context) == "Run /code-review on this branch.")
    }

    @Test func keepsSentencePunctuationAfterTheName() {
        #expect(format("then run slash review.", context: context) == "then run /review.")
    }

    @Test func strayEngineSlashResolvesLikeASpokenOne() {
        #expect(format("Type / init so it works", context: context) == "Type /init so it works")
        #expect(format("so run/slash compact and keep", context: context) == "so run /compact and keep")
    }

    @Test func refusesANameThatIsNotInTheContext() {
        #expect(format("run slash grill you on this", context: context) == "run/grill you on this")
        #expect(format("run slash simplify now", context: context) == "run/simplify now")
    }

    @Test func aNameInsideAPathIsNotACommand() {
        #expect(format("open src slash lib slash review", context: context) == "open src/lib/review")
        #expect(format("open src slash review dot ts", context: context) == "open src/review.ts")
    }

    @Test func resolvesMultiWordFlag() {
        #expect(format("add dash dash dry run flag", context: context) == "add --dry-run flag")
    }

    @Test func vocabularyIsEveryNameTheResolverCanWrite() {
        let small = FormattingContext(skills: ["grill-me"], slashCommands: ["init"], flags: ["dry-run"])
        #expect(small.vocabulary == ["/grill-me", "/init", "--dry-run"])
    }
}

struct ProsePassthroughTests {
    private let context = FormattingContext(skills: ["grill-me", "review"], slashCommands: ["compact", "help", "init"])

    @Test(arguments: [
        "I think the meeting went well but we still need to decide on who owns the follow-up before Friday",
        "Can you summarize the main differences between the two approaches in a couple of sentences?",
        "The build has been slow all week, and I need the cache is not being shared between machines.",
        "Please write a short note thanking the team for a quick turnaround on the release.",
        "Could you review the help docs and compact them into one page?",
    ])
    func proseIsUnchanged(_ sentence: String) {
        #expect(format(sentence, context: context) == sentence)
    }
}

struct DisfluencyTests {
    @Test func fillerBetweenCommasKeepsTheCommaBeforeIt() {
        #expect(format("So, uh, I need a hand", context: none) == "So, I need a hand")
        #expect(format("I bought apples, um, oranges", context: none) == "I bought apples, oranges")
    }

    @Test func fillerStartingASentenceHandsOnItsCapital() {
        #expect(format("Uh, can you check the logs?", context: none) == "Can you check the logs?")
        #expect(format("That's done. Um, next we deploy.", context: none) == "That's done. Next we deploy.")
    }

    @Test func fillerVariantsAndAFillerEndingTheSentence() {
        #expect(format("Umm, so er we ship it, hmm.", context: none) == "So we ship it.")
        #expect(format("Uhm I think ahh erm it works", context: none) == "I think it works")
    }

    @Test func bareParakeetFillerIsDropped() {
        #expect(
            format("Add userId and session token feels uh they're optional", context: none)
                == "Add userId and session token feels they're optional"
        )
    }

    @Test func fillerBetweenDashDashAndTheFlagName() {
        #expect(format("run with dash dash uh verbose", context: none) == "run with --verbose")
    }

    @Test func stuttersOfFunctionWordsCollapse() {
        #expect(format("which models conform to to it.", context: none) == "which models conform to it.")
        #expect(format("The the build is red", context: none) == "The build is red")
        #expect(format("fix the uh the cache", context: none) == "fix the cache")
    }

    @Test(arguments: [
        "I know that that is true.",
        "What it is is a cache miss.",
        "They had had enough.",
        "Draw an ER diagram for the UM module.",
        "Like, you know, I actually think so.",
        "Remove filler words like uh and um from the text.",
    ])
    func legitimateRepeatsMentionsAndAcronymsStay(_ sentence: String) {
        #expect(format(sentence, context: none) == sentence)
    }

    @Test func threeOrMoreRepeatsOfAnyWordCollapse() {
        #expect(format("it's it's it's it's not cleaning", context: none) == "it's not cleaning")
        #expect(format("We're we're we're ready", context: none) == "We're ready")
        #expect(format("the build is is is red", context: none) == "the build is red")
        #expect(format("I know that that that is true", context: none) == "I know that is true")
        #expect(format("it's uh it's it's not working.", context: none) == "it's not working.")
        #expect(format("it works it works it works.", context: none) == "it works.")
    }

    @Test func longPhraseRepeatsCollapse() {
        #expect(format("I think I think I think we should ship", context: none) == "I think we should ship")
        #expect(format("the build the build the build is red", context: none) == "the build is red")
    }

    @Test(arguments: [
        "that is very very very good",
        "No, no, no, that is wrong.",
        "no no no stop",
        "She laughed ha ha ha and left.",
        "add dot dot dot at the end",
        "It's it's fine.",
        "I think I think we should ship",
        "it's, it's, it's fine",
        "it's it's. it's fine",
    ])
    func emphasisPunctuatedAndPairedRepeatsStay(_ sentence: String) {
        #expect(format(sentence, context: none) == sentence)
    }

    @Test func danglingConnectiveAtTheEndGoes() {
        #expect(format("it's not cleaning up everything properly and", context: none) == "it's not cleaning up everything properly")
        #expect(format("check the logs but", context: none) == "check the logs")
        #expect(format("deploy it or", context: none) == "deploy it")
        #expect(format("ship it because", context: none) == "ship it")
        #expect(format("run the tests and then", context: none) == "run the tests")
        #expect(format("run the tests so then", context: none) == "run the tests")
        #expect(format("check the logs and um", context: none) == "check the logs")
    }

    @Test func danglingConnectiveTakesItsCommaAndKeepsOrCarriesTheFullStop() {
        #expect(format("we need the API, and", context: none) == "we need the API")
        #expect(format("We shipped it. And", context: none) == "We shipped it.")
        #expect(format("We shipped it and.", context: none) == "We shipped it.")
        #expect(format("We shipped it, and uh.", context: none) == "We shipped it.")
    }

    @Test(arguments: [
        "I think so",
        "see you then",
        "looks like",
        "Why did it fail? Because.",
        "Use the red and blue one",
        "and",
        "Tom and Jerry",
        "and then there were none",
    ])
    func connectivesThatEndRealSentencesOrSitMidTextStay(_ sentence: String) {
        #expect(format(sentence, context: none) == sentence)
    }

    @Test func usersDictationThatCameThroughUntouched() {
        #expect(
            format("So currently the app what it doesn't do is that it's it's it's it's not cleaning up everything properly and", context: none)
                == "So currently the app what it doesn't do is that it's not cleaning up everything properly"
        )
    }

    @Test func usersOwnRequest() {
        let spoken = "So, a couple of things now. I need the dictation app to remove any filler words like uh and um that is priority number one. Second priority is if I am dictating a list of things, uh, it needs to be smart enough to format them in bullet points or numbered lists."
        #expect(
            format(spoken, context: none)
                == "So, a couple of things now. I need the dictation app to remove any filler words like uh and um that is priority number one. Second priority is if I am dictating a list of things, it needs to be smart enough to format them in bullet points or numbered lists."
        )
    }
}

struct ListTests {
    @Test func ordinalsBecomeANumberedListAfterTheirLeadIn() {
        #expect(
            format("I need three things. First, the API, second, the UI, and third, the docs.", context: none)
                == "I need three things:\n1. The API\n2. The UI\n3. The docs"
        )
    }

    @Test func ordinalsWithoutALeadIn() {
        #expect(
            format("first fix the build, second update the docs, and then third ship it", context: none)
                == "1. Fix the build\n2. Update the docs\n3. Ship it"
        )
    }

    @Test func firstlySecondlyFinally() {
        #expect(
            format("Firstly, we profile the app. Secondly, we fix the hot path. Finally, we measure again.", context: none)
                == "1. We profile the app\n2. We fix the hot path\n3. We measure again"
        )
    }

    @Test func numberOneNumberTwo() {
        #expect(format("number one milk number two eggs number three bread", context: none) == "1. Milk\n2. Eggs\n3. Bread")
    }

    @Test func countedNumbersNeedTheirComma() {
        #expect(format("Steps, one, clone the repo. two, run the tests.", context: none) == "Steps:\n1. Clone the repo\n2. Run the tests")
    }

    @Test func spokenBullets() {
        #expect(format("bullet milk bullet eggs bullet bread", context: none) == "- Milk\n- Eggs\n- Bread")
        #expect(format("Shopping list, bullet point oat milk next bullet eggs", context: none) == "Shopping list:\n- Oat milk\n- Eggs")
    }

    @Test func dashStartingAnItemIsABullet() {
        #expect(format("Dash buy milk dash call mom", context: none) == "- Buy milk\n- Call mom")
    }

    @Test func flagsInsideBulletItemsStillWork() {
        let context = FormattingContext(flags: ["dry-run"])
        #expect(
            format("bullet run with dash dash dry run bullet build with dash c release", context: context)
                == "- Run with --dry-run\n- Build with -c release"
        )
    }

    @Test func aMultiSentenceItemKeepsItsFullStop() {
        #expect(
            format("First, run the tests. They take a minute. Second, read the log.", context: none)
                == "1. Run the tests. They take a minute.\n2. Read the log"
        )
    }

    @Test func questionItemsKeepTheirQuestionMark() {
        #expect(format("First, can we ship? Second, who owns it?", context: none) == "1. Can we ship?\n2. Who owns it?")
    }

    @Test func proseAfterTheListGetsItsOwnParagraph() {
        #expect(
            format("Two things. First, fix it. Second, ship it. Then we celebrate.", context: none)
                == "Two things:\n1. Fix it\n2. Ship it\n\nThen we celebrate."
        )
    }

    @Test func identifiersKeepTheirCase() {
        #expect(
            format("First, useAuth breaks. Second, src slash lib is empty.", context: none)
                == "1. useAuth breaks\n2. src/lib is empty"
        )
    }

    @Test(arguments: [
        "First, let me explain the bug.",
        "Give me a second, first I need coffee.",
        "First and second place went to us.",
        "First, we tried a patch. Finally, it worked.",
        "The second test and the third test fail.",
        "Add a bullet point about latency and a bullet point about cost.",
        "One of the two tests failed.",
        "Count: 1, 2, 3.",
        "Second priority is the list, so number two waits.",
    ])
    func proseWithMarkerWordsStaysProse(_ sentence: String) {
        #expect(format(sentence, context: none) == sentence)
    }
}

struct SpokenBreakTests {
    @Test func newLineAndNewParagraphAtAClauseStart() {
        #expect(format("Thanks for the review, new line, Bob", context: none) == "Thanks for the review,\nBob")
        #expect(format("Hi team. New paragraph. the release is out.", context: none) == "Hi team.\n\nThe release is out.")
    }

    @Test func newLineInsideASentenceIsProse() {
        #expect(format("add a new line after the import", context: none) == "add a new line after the import")
    }
}
