# Findings: Dictation Engine Benchmark (Spike 0)

Plain Parakeet TDT 0.6B v2 (FluidAudio) is the engine for the real app. The dev-term formatting will be our own layer on top of it, not the engine's vocabulary biasing.

The biased Parakeet variant topped the spec's winner rule at 94.1% lenient and 72.5% strict token accuracy. That score is inflated, because `vocab.txt` held every token in the test. It also inserted a wrong vocab term 13 times in 35 clips, for example "compare" became `/compact` and "empty" became `TypeScript`. The token metric does not penalise these insertions. Biased Whisper made none, or almost none, but runs at 1.25 to 1.5 s warm, about 3x the 500 ms budget.

Plain Parakeet's errors are formatting misses ("slash lib"), not wrong words. It runs at 43 ms warm. Closing the gap between its lenient score (74.5%) and strict score (5.9%) is the formatting layer's job. That layer uses deterministic symbol rules plus a resolver that can only choose names that really exist, such as the installed skills.

## Results

Run `results/20261016-163929`. Apple M5, 16 GB, macOS 26.5. 35 self-recorded clips from one speaker, release build.

| variant | lenient % | strict % | warm p50 | 5 s clip est. | false vocab insertions |
|---|---|---|---|---|---|
| parakeet-v2+vocab | 94.1 | 72.5 | 190 ms | 0.15 s | 13 |
| whisper-turbo+vocab | 84.3 | 37.3 | 1485 ms | 1.19 s | 0 |
| whisper-turbo | 82.4 | 15.7 | 514 ms | 0.41 s | n/a |
| whisper-small.en+vocab | 80.4 | 31.4 | 1254 ms | 1.02 s | 2 |
| parakeet-v2 | 74.5 | 5.9 | 43 ms | 0.03 s | n/a |
| whisper-small.en | 72.5 | 11.8 | 245 ms | 0.20 s | n/a |

File paths are the weakest category for every unbiased engine. Plain Parakeet got 2 of 9.

## What this means for the app

- Ship one engine, Parakeet v2, unbiased.
- Format spoken symbols with deterministic rules ("slash" becomes `/`, "dash dash" becomes `--`, and so on), then resolve names against real sources. Skills come from `~/.claude/skills`. Repo paths come later.
- Keep the `bench` harness. Strict token accuracy is the metric that measures the formatting layer.
- Add a false-insertion count to scoring before trusting any biasing again.
- With ~35 clips from one speaker, these results show direction only.
