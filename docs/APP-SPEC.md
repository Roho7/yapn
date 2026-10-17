# Spec: Dictation App v1

## Purpose
A macOS menu bar app for developers. Hold Right Option, speak, release. The text appears at the cursor in whatever app has focus, with dev terms written the way code needs them: `/grill-me`, `--dry-run`, `useAuthProvider`.

Engine choice and the reasons for it are in [FINDINGS.md](FINDINGS.md).

## Decisions
| Area | Decision |
|---|---|
| Engine | Parakeet TDT 0.6B v2 through FluidAudio, unbiased. Loaded once at launch and kept warm |
| Trigger | Hold Right Option to record, release to transcribe and insert |
| Insertion | Save the clipboard, put the text on it, post Cmd+V to the focused app, restore the clipboard |
| Formatting | Our own layer on top of the raw transcript: deterministic spoken-symbol rules, then a resolver that only picks names that exist |
| Resolver sources v1 | Skills in `~/.claude/skills`, plus a built-in list of Claude Code slash commands. Repo paths are out of scope for v1 |
| Form | SwiftPM executable target `Dictation`, bundled into `Dictation.app` by `scripts/bundle.sh`. No Xcode project, so the unaccepted Xcode license does not block us |
| UI | Menu bar item (`LSUIElement`), plus a small floating HUD that shows recording and transcribing |
| Latency budget | Release to text at the cursor under 300 ms for a 5 s utterance |

## Core shapes
- **`DictationState`.** A state machine: `idle → recording → transcribing → inserting → idle`, with `failed(reason)`. A pure reducer takes events (`hotkeyDown`, `hotkeyUp`, `transcribed(text)`, `inserted`, `failed`) and returns the next state plus effects. Every UI element renders from this state.
- **`Formatter`.** `format(_ raw: String, context: FormattingContext) -> String`. It is pure. `FormattingContext` holds the known names (skills, slash commands). Formatting is an ordered list of rules, not branches spread across files.
- **`SkillCatalog`.** It reads the skill names from disk once at launch and refreshes when the menu opens.

## Measuring the formatter
`results.json` stores raw transcripts, so the formatter can be scored on the 35 recorded clips without re-running the engine: `bench rescore results/<ts> --format`. Strict token accuracy is the formatter's metric. Baseline: plain Parakeet at 5.9% strict and 74.5% lenient. A good formatter moves strict towards lenient without adding false insertions.

## LLM cleanup (opt-in)
An optional pass on Apple's on-device model (Foundation Models, macOS 26 with Apple Intelligence on) for what rules cannot do: self-corrections ("meet Monday, no wait, Tuesday" becomes "meet Tuesday"), heavy hesitation ("we should, um, we should, you know, add a test" becomes "we should add a test"), and lists spoken without markers. It is off by default.

- Turn it on for one launch with `open build/Dictation.app --args --llm-cleanup`. To keep it on, run `defaults write dev.roho.dictation llmCleanup -bool YES` and then `open build/Dictation.app`. `defaults delete dev.roho.dictation llmCleanup` turns it off again.
- The menu shows `LLM cleanup: off`, `on`, or `unavailable (<reason>)`. While it is unavailable, dictations use the rule output. The app checks again when the menu opens and when a dictation starts.
- Order: rules `format()` first, then the cleaner on its output. The rules write the code tokens (`/grill-me`, `--dry-run`, paths), so the cleaner's output can be checked against them.
- Only text with a correction cue ("actually", "no wait", "sorry", "I mean", "scratch"), a restart ("we should, we should", "I was going to I was going to"), two or more crutch words or comma-split repeats ("so, like, the, the build"), or a comma-separated run reaches the model. One "so" or "you know" is how people talk, so it does not. Everything else costs nothing.
- `reviewCleanup` keeps the model's text only if every rule token is still there, unchanged, and any question mark stays. Each run of deleted words must be one of: crutch words ("um", "you know", "kind of", "basically", a "like" that is not a verb, "so" or "okay" opening a clause), a repeat of the words beside it, a clause of two to six words that the next clause restarts ("she wants, she needs"), or, with a correction cue, a run holding the cue. Doubles that can be English ("had had", "that that", "what it is is") and emphasis ("very very") stay. Without a cue nothing may be added and at least half the words stay. With a cue at most two words may be added. Anything else falls back to the rule output, and the log says why.
- The model's warm state fades after 5 to 10 s of idle, and a cold call takes 630 to 770 ms instead of ~220 ms. The app prewarms when Right Option goes down, which needs ~700 ms of lead time.
- Each dictation logs `cleanup %.1f ms` next to the other timings, plus the cleaned text or the reason for the fallback.
- Measure it with `bench rescore results/<ts> --cleanup`. `--cleanup-all` sends every clip to the model, with no gate. The repair set is `data/repairs.txt`. Build its clips with `scripts/make-repair-clips.sh`, then run `bench run --clips data/repair-clips --engines parakeet-v2`. The hesitation set is `data/hesitations.txt`: `scripts/make-repair-clips.sh data/hesitations.txt data/hesitation-clips`, then `bench run --clips data/hesitation-clips --engines parakeet-v2`.
- `bench clean` takes raw transcripts on stdin, one per line, and prints what the formatter and the cleanup make of each. `--all` skips the gate.

## Styles per app
The text is written for the app it lands in. When Right Option goes down, the app reads the frontmost app's bundle id and name and, through the Accessibility grant it already has, the focused window's title. `resolveStyle` picks a style from one ordered table in `Sources/DictationCore/Style/DictationStyle.swift`; the first matching row wins.

| Rule | Style |
|---|---|
| A terminal whose window title holds "claude" or a Claude Code spinner glyph (✳ ✶ ✻ ✽ ✢) | `claude-code` |
| The Claude app (`com.anthropic.claudefordesktop`) | `claude-code` |
| Any other terminal: Terminal, iTerm2, Warp, Ghostty, kitty, Alacritty, WezTerm, Hyper | `shell` |
| A browser (Safari, Chrome, Arc, Dia, Firefox, Brave, Edge) whose tab title holds "LinkedIn" | `formal` |
| Mail | `formal` |
| Everything else, editors with built-in terminals included | `default` |

- **`default` and `claude-code`** run the pipeline above unchanged.
- **`formal`** deletes in the rules what is safe to delete without the model: "basically", "honestly", "literally", "kind of" and "sort of" where they name no kind, "like" and "you know" at a pause (next to a comma or after a leading conjunction), and "And", "But", "So" or "Plus" opening a sentence. It capitalises and closes every sentence. Then it always sends the text to the model for the rest: repeats, restarts, "just", "really", "super". The review allows case and punctuation changes and up to two added words, and otherwise holds the default guard: code tokens verbatim, questions stay questions, half the words stay.
- **`shell`** writes a command line: one line, no sentence punctuation, no capital on the first word. It first undoes the engine's spellings: letters said one by one join ("C D S R C" is `cd src`), a lone letter is lowercase unless "capital" comes first, known programs and subcommands lose their capitals ("NPM", "Docker Compose"), and "get" before a git subcommand is `git`. On top of the spoken symbols, "verbose flag" or "flag verbose" is `--verbose`, "dry run flag" is `--dry-run` (multi-word names only from a known list), "short flag v" is `-v`, "long flag X" is `--X`, "argument X" or "pass X" is `X`, and "with the" before a flag goes. Text holding a word the model may delete ("run", "with", "the", "message") goes to the model, which may only delete those words, add quotes, and add `-m` or `--`: "git commit with message fix login bug" becomes `git commit -m "fix login bug"`. Anything else falls back to the rule output. The pasted text never holds a newline, so pasting never runs the command.
- The log has a `style:` line per dictation with the app, the window title and the rule that matched. The menu shows `Style: <name> (<app>)` for the frontmost app when it opens. History entries record the style and the window title.
- Override the table per app: `defaults write dev.roho.dictation styleOverrides -dict com.apple.Terminal claude-code`. Values are `default`, `claude-code`, `shell`, `formal`. `defaults delete dev.roho.dictation styleOverrides` removes them.
- Measure a style on stored transcripts with `bench rescore results/<ts> --cleanup --style formal` or `bench clean --style shell`. The sets are `data/styles/formal.txt` and `data/styles/shell.txt`; build their clips with `scripts/make-repair-clips.sh data/styles/formal.txt data/styles/formal-clips` and run `bench run --clips data/styles/formal-clips --engines parakeet-v2`.

## Real-voice eval set
The recorded clips are read prompts. Real dictation has stutters, restarts and self-corrections that read prompts lack, so every change to formatting or cleanup is also measured on the user's own dictations.

- **Keep history.** It is off by default. Turn it on with the menu item `Keep dictation history`, or with `defaults write dev.roho.dictation keepHistory -bool YES`, or for one launch with `open build/Dictation.app --args --keep-history`. The menu toggle writes the same default. `Open History Folder` shows the entries in Finder.
- **What is kept.** Each completed dictation writes `~/Library/Application Support/Dictation/history/<yyyyMMdd-HHmmss-SSS>/`. `audio.wav` holds the exact 16 kHz samples Parakeet transcribed. `entry.json` holds the raw transcript, the formatted text, the cleanup outcome (cleaned text, fallback reason, or skipped), what was pasted, the frontmost app's bundle id, and the stage timings. The write runs off the main actor after the paste, so it adds no latency. A failed write only logs.
- **Privacy.** History stays on this Mac and is never uploaded. Delete an entry with `d` in `bench label`, or delete the folder. `data/real-clips/` is git-ignored for the same reason.
- **Label.** `bench label` walks the unlabelled entries oldest first and shows the raw and pasted text. Enter accepts the pasted text as the reference. `e` opens it in `$EDITOR` (`nano` if unset) to fix, and `r` opens the raw transcript instead. `p` plays the audio, `s` skips for now, `d` deletes the entry, `q` quits. Wrap dev tokens in backticks (`` run `/grill-me` ``) to score them as tokens. Each labelled entry becomes the next clip in `data/real-clips/` (category `dictation`) and gets a `label.json`, so the command resumes where it stopped. `--history` and `--out` change either directory.
- **Measure.** Transcribe the clips once, then rescore as often as the rules or the cleaner change:

  ```sh
  bench run --clips data/real-clips --engines parakeet-v2
  bench rescore results/<ts> --format --cleanup
  ```

  `worse` counts the clips a stage made worse: more word edits against the reference after the stage than before it. Cleanup should only remove errors, so `worse` on the `+format+cleanup` row is the over-edit count, and it should stay at 0. The per-clip list under the table marks each one `WORSE !`.

## Permissions
- Microphone (`NSMicrophoneUsageDescription`).
- Accessibility, for the global Right Option monitor and for posting Cmd+V.
- On first launch, explain both and deep-link to System Settings.
- macOS ties these grants to the code signature. Ad-hoc signing changes it on every build, which resets the grants. There is no signing identity on this machine yet. Prefer a stable self-signed identity, and otherwise document the re-grant step.

## Out of scope for v1
Repo path resolution, LLM cleanup on by default, streaming partial results, the notch UI, a history browser in the app, distribution and notarisation, multilingual.

## Done when
1. `bench rescore` on the recorded run shows the formatter's strict accuracy next to the raw baseline.
2. Holding Right Option and saying "run slash grill me" inserts `run /grill-me` into a terminal.
3. Your clipboard is the same after a dictation as before it.
4. Release-to-insert latency is logged and under budget on the M5.
