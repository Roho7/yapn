# Spec: Dictation Engine Benchmark (Spike 0)

## Purpose
Pick the speech-to-text engine for a developer-focused macOS dictation app (dictating code, file paths and Claude skill invocations). Compare **Whisper** and **NVIDIA Parakeet** running locally on Apple Silicon, on speech that sounds like real developer dictation.

This is a throwaway-quality spike, but the core engine code should be reusable in the real app.

## Decisions
| Area | Decision |
|---|---|
| Form | Swift CLI benchmark plus a tiny menu bar app for live comparison |
| Toolchain | Full Xcode (install first). Xcode project for the app; SwiftPM package for the shared core and CLI |
| Runtimes | **WhisperKit** (Core ML / Neural Engine) and **FluidAudio** (Parakeet on Core ML) |
| Models | Whisper `large-v3-turbo`, Whisper `small.en`, Parakeet TDT 0.6B **v2** |
| Biasing | Extra variant: each Whisper model run plain and with a vocab prompt. Parakeet biased variant only if FluidAudio supports it, otherwise recorded as a gap |
| Test data | Self-recorded dev prompts read from `prompts.txt` (about 30 utterances) |
| Metrics | WER, dev-token accuracy (lenient + strict), latency (cold/warm) + real-time factor, peak memory + model load time |
| Live mode | Hold **Right Option**, speak, release. All engines transcribe **one after another**; a popover shows the transcripts and latencies side by side; click to copy. No auto-paste |
| Output | **HTML report** per run, under `results/<timestamp>/report.html` |
| Winner rule | Highest **lenient dev-token accuracy**, provided warm latency is **under 500ms for a ~5s clip**. Ties: WER, then memory |
| Location | `~/Documents/MAIN/CODE/dictation-app` (new git repo) |
| Hardware baseline | Apple M5, 16GB RAM, macOS 26.5 |

## Repo layout
```
dictation-app/
├─ Package.swift                 # SwiftPM: DictationCore (library) + bench (CLI)
├─ Sources/
│  ├─ DictationCore/
│  │  ├─ Engine.swift            # protocol TranscriptionEngine
│  │  ├─ WhisperKitEngine.swift
│  │  ├─ ParakeetEngine.swift    # FluidAudio
│  │  ├─ AudioRecorder.swift     # AVAudioEngine → 16kHz mono Float32
│  │  ├─ Scoring.swift           # WER, token lenient/strict
│  │  └─ Metrics.swift           # timing, memory sampling
│  └─ bench/                     # CLI entry point
├─ App/                          # Xcode project: menu bar app, depends on DictationCore
├─ data/
│  ├─ prompts.txt                # test utterances with tagged dev tokens
│  ├─ vocab.txt                  # biasing vocabulary
│  └─ clips/                     # recorded WAV + JSON ground truth
├─ results/<timestamp>/report.html
└─ docs/SPEC.md
```

## Core abstraction
```swift
protocol TranscriptionEngine {
    var id: String { get }                  // e.g. "whisper-turbo+vocab"
    func load() async throws -> LoadStats   // load time, memory delta
    func transcribe(_ samples: [Float], vocab: [String]?) async throws -> String
    func unload()
}
```
Engine variants (5, or 6 if Parakeet supports biasing):
`whisper-turbo`, `whisper-turbo+vocab`, `whisper-small.en`, `whisper-small.en+vocab`, `parakeet-v2`, (`parakeet-v2+vocab`).

## Test data format
`prompts.txt`: one utterance per line. Dev tokens are wrapped in backticks with their written form:
```
open `src/lib/auth.ts` and refactor `useAuthProvider`
run `/code-review` on this branch
add a `--dry-run` flag to the deploy script
use the `/chapterize` skill on this doc
```
- Categories to cover: Claude Code prompts, `/skill` invocations, file paths, camel/snake identifiers, CLI flags, plain prose (a few, as a control).
- **Recording flow** (`bench record`): show each prompt, hold a key to record, save `clips/NNN.wav` plus `NNN.json` `{ text, tokens[] }`. Re-record is allowed.

## Scoring
- **WER:** normalise case and punctuation, expand backtick tokens to their spoken words, then standard word-level edit distance.
- **Dev tokens, lenient:** lowercase and strip spaces and punctuation from both the token and the transcript; the token counts as a hit if its normalised form appears (`use auth provider` → `useauthprovider` ✓).
- **Dev tokens, strict:** the exact written token appears verbatim in the transcript.
- Report per engine: overall, per category, and per clip.

## Performance measurement
- **Load:** model load time and memory delta (`task_info` phys_footprint) per engine.
- **Cold vs warm:** the first transcription after load is cold; the median of the remaining runs is warm.
- **Latency:** wall time from handing over the audio buffer to the final text.
- **RTF:** processing time ÷ audio duration.
- **Peak memory** sampled during transcription.
- Engines run **one after another** with only one loaded at a time, so they don't share the Neural Engine or memory.

## CLI
```
bench record  [--prompts data/prompts.txt]          # build the test set
bench run     [--engines all|id,...] [--vocab data/vocab.txt]
bench report  results/<timestamp>                   # (re)generate HTML
```
`bench run` loads each engine, transcribes all clips, writes `results/<ts>/results.json` and generates `report.html`.

## HTML report
- Summary table: engine × (lenient token %, strict token %, WER, warm latency p50/p95, RTF, load time, peak memory). **Winner highlighted** using the winner rule.
- Per-category breakdown.
- Per-clip view: audio player, expected text, and every engine's transcript side by side, with missed tokens highlighted.
- A single self-contained HTML file (inline CSS and JS), so it opens offline.

## Menu bar app
- `LSUIElement` (no Dock icon). Menu: engines on/off, preload models, open the last report, quit.
- **Hold Right Option** to record (modifier-flag monitoring; requires the Accessibility permission). Release to transcribe with each enabled engine one after another.
- Popover: one row per engine with transcript, latency and RTF; click a row to copy.
- Live clips are optionally saved to `data/live/` for labelling later.
- Permissions: microphone (`NSMicrophoneUsageDescription`) and Accessibility. Explain both on first launch.

## Out of scope
Code normalisation (casing and symbol grammar), repo or skill indexing, text insertion and auto-paste, the notch UI, LLM polish, streaming partial results, distribution and notarisation, Hinglish and multilingual support (Parakeet v3 is a later spike).

## Done when
1. A recorded set of at least 30 dev clips exists, with ground truth.
2. `bench run` produces an HTML report for all engine variants on this M5.
3. The menu bar app works live: hold Right Option, speak, and see the transcripts side by side.
4. A one-paragraph conclusion in `docs/FINDINGS.md`: which engine wins, whether biasing closes the dev-token gap, and what that means for the real app.

## Open risks
- FluidAudio may not support vocabulary biasing for Parakeet. Then the comparison is unbiased Parakeet against biased Whisper; record it as a gap.
- The first download and Core ML compilation of each model can take minutes. Exclude it from the load-time metric, but log it.
- Right Option monitoring needs the Accessibility permission, which can be fiddly for apps built locally that aren't properly signed. A fallback hotkey through the KeyboardShortcuts package avoids this.
- With only ~30 clips from one speaker, the results show direction only.

## Prerequisites
1. Install Xcode from the App Store, then run `sudo xcode-select -s /Applications/Xcode.app`.
2. About 3GB free for models (turbo ~1.6GB, small.en ~0.5GB, Parakeet ~0.6GB).
