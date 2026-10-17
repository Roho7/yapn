import AppKit
import DictationCore

/// Owns the dictation state, runs the reducer's effects, and re-renders the menu and status indicator on every change.
@MainActor
final class AppController {
    private(set) var state = DictationState.loading
    private(set) var last: LastDictation?
    private var releasedAt: Double?
    private let audio: any AudioSource
    private let engine = ParakeetEngine(variant: EngineVariant(model: .parakeetV2, biased: false), vocab: [])
    private let inserter = Inserter()
    /// False for `--selftest <wav> --no-paste`, which runs everything but the paste.
    private let paste: Bool
    private let indicator: any StatusIndicator
    private var shownPhase = IndicatorPhase.hidden
    private lazy var menu = StatusMenu(
        snapshot: { [unowned self] in (state, last, cleanupState.menu, styleLine, keepHistory) },
        onMenuOpen: { [unowned self] in
            formattingContext = loadFormattingContext()
            styleOverrides = loadOverrides()
            styled = resolve(captureTarget())
            refreshCleanup()
            refreshAccessibility()
        },
        onToggleHistory: { [unowned self] in toggleHistory() },
        onToggleCleanup: { [unowned self] in toggleCleanup() }
    )
    private lazy var hotkey = RightOptionMonitor { [unowned self] isDown, at in
        send(isDown ? .hotkeyDown(at: at) : .hotkeyUp(at: at))
    }
    /// Skill names come from disk at launch and again whenever the menu opens.
    private var formattingContext = loadFormattingContext()
    private var accessibilityGranted = Permission.accessibility.isGranted
    private var accessibilityPoll: Timer?
    private var cleanupState: CleanupState
    static let keepHistoryKey = "keepHistory"
    static let llmCleanupKey = "llmCleanup"
    private(set) var keepHistory: Bool
    private let history = HistoryStore(directory: HistoryStore.defaultDirectory)
    /// The transcription waiting to be pasted, kept so the history entry can hold every stage.
    private var pendingTake: TranscribedTake?
    /// The last history save, which runs off the main actor; its value is the entry's directory, nil if it failed.
    private(set) var historyWrite: Task<URL?, Never>?
    /// The app the next or current dictation is for and the style it resolved to; set at hotkey-down and when the menu opens.
    private(set) var styled: StyledTarget?
    private var styleOverrides = loadOverrides()

    var menuTitles: [String] { menu.titles }

    init(audio: any AudioSource, indicator: any StatusIndicator = NoStatusIndicator(), llmCleanup: Bool = false, keepHistory: Bool = false, paste: Bool = true) {
        self.audio = audio
        self.indicator = indicator
        self.keepHistory = keepHistory
        self.paste = paste
        cleanupState = llmCleanup ? .unavailable("not checked yet") : .off
    }

    func start(listenForHotkey: Bool) {
        log(keepHistory ? "history: on, saving each dictation to \(history.directory.path)" : "history: off")
        refreshCleanup()
        menu.render()
        if listenForHotkey {
            enableEditorAccessibilityOnActivation()
            hotkey.install()
            if !accessibilityGranted { pollForAccessibility() }
        }
        Task { await loadEngine() }
    }

    func send(_ event: DictationEvent) {
        let (next, effects) = reduce(state, event)
        if case .hotkeyUp(let at) = event, next == .transcribing { releasedAt = at }
        if next != state { log("state \(state) -> \(next)") }
        state = next
        // Effects first: painting the indicator and menu costs several ms that should not delay transcription.
        effects.forEach(run)
        let phase = IndicatorPhase(state)
        if phase != shownPhase {
            shownPhase = phase
            indicator.show(phase)
        }
        menu.render()
    }

    func updateLevel(_ level: Float) {
        guard shownPhase == .listening else { return }
        indicator.updateLevel(level)
    }

    private func run(_ effect: DictationEffect) {
        switch effect {
        case .startRecording:
            do { try audio.start() } catch { send(.failed("\(error)")) }
            let (target, captureSeconds) = measure { captureTarget() }
            let styled = resolve(target)
            self.styled = styled
            log(String(format: "style: %@ for %@ (%@, title %@, focus %@; rule: %@; read in %.1f ms)",
                       styled.decision.style.rawValue, target.appName ?? "?", target.bundleID ?? "no bundle id",
                       target.windowTitle.map { "\"\($0)\"" } ?? "none", target.focusedElement.map { "\"\($0)\"" } ?? "none",
                       styled.decision.rule, captureSeconds * 1000))
            // The model's warm state fades within seconds, so it is rebuilt while the user speaks.
            refreshCleanup()
            let instructions = cleanupInstructions(for: styled.decision.style)
            if let cleaner = cleanupState.cleaner { Task { await cleaner.prewarm(instructions: instructions) } }
        case .cancelRecording:
            _ = audio.stop()
        case .stopAndTranscribe:
            let (samples, stopSeconds) = measure { padToMinimum(audio.stop()) }
            let cleaner = cleanupState.cleaner
            let styled = styled ?? resolve(DictationTarget(bundleID: nil, appName: nil, windowTitle: nil))
            let style = styled.decision.style
            // Detached so inference starts now instead of after the main actor finishes rendering.
            Task.detached { [engine, formattingContext] in
                do {
                    let (raw, seconds) = try await timed { try await engine.transcribe(samples) }
                    let (formatted, formatSeconds) = measure { format(raw, context: formattingContext, style: style) }
                    let cleaned = if let cleaner { await cleanup(formatted, with: cleaner, style: style) } else { CleanupResult?.none }
                    log(String(format: "audio %.2fs, stop+convert %.1f ms, transcribe %.1f ms, format %.2f ms",
                               Double(samples.count) / targetSampleRate, stopSeconds * 1000, seconds * 1000, formatSeconds * 1000)
                        + (cleaned.map { String(format: ", cleanup %.1f ms", $0.seconds * 1000) } ?? ""))
                    log("raw: \(raw)")
                    log("formatted: \(formatted)")
                    if let cleaned { log(cleanupLogLine(cleaned.outcome)) }
                    await self.transcribed(TranscribedTake(
                        samples: samples, styled: styled, raw: raw, formatted: formatted, cleanup: cleaned,
                        stopMs: stopSeconds * 1000, transcribeMs: seconds * 1000, formatMs: formatSeconds * 1000
                    ))
                } catch {
                    await self.send(.failed("transcription failed: \(error)"))
                }
            }
        case .insert(let text):
            Task {
                let report = paste
                    ? await inserter.insert(text)
                    : InsertReport(pastePostedAt: ProcessInfo.processInfo.systemUptime, snapshotMs: 0, firstReadMs: nil, restored: true)
                let latencyMs = (report.pastePostedAt - (releasedAt ?? report.pastePostedAt)) * 1000
                last = LastDictation(text: text, releaseToPasteMs: latencyMs, firstPasteboardReadMs: report.firstReadMs)
                log(String(format: "release->paste %.1f ms (snapshot %.2f ms), first pasteboard read %@, clipboard %@",
                           latencyMs, report.snapshotMs,
                           report.firstReadMs.map { String(format: "%+.1f ms", $0) } ?? "never",
                           report.restored ? "restored" : "left alone (changed by someone else)"))
                if keepHistory, let take = pendingTake {
                    saveHistory(take, pasted: text, report: report, releaseToPasteMs: latencyMs)
                }
                pendingTake = nil
                send(.inserted)
            }
        }
    }

    private func transcribed(_ take: TranscribedTake) {
        pendingTake = take
        send(.transcribed(take.text))
    }

    /// Runs after the paste and off the main actor, so keeping history never adds latency. Failures only log.
    private func saveHistory(_ take: TranscribedTake, pasted: String, report: InsertReport, releaseToPasteMs: Double) {
        let entry = HistoryEntry(
            recordedAt: Date(),
            raw: take.raw,
            formatted: take.formatted,
            cleanup: take.cleanup.map { HistoryCleanup($0.outcome) },
            pasted: pasted,
            frontmostApp: take.styled.target.bundleID,
            windowTitle: take.styled.target.windowTitle,
            style: take.styled.decision.style,
            timings: HistoryTimings(
                audioSeconds: Double(take.samples.count) / targetSampleRate,
                stopMs: take.stopMs,
                transcribeMs: take.transcribeMs,
                formatMs: take.formatMs,
                cleanupMs: take.cleanup.map { $0.seconds * 1000 },
                releaseToPasteMs: releaseToPasteMs,
                firstPasteboardReadMs: report.firstReadMs
            )
        )
        let samples = take.samples
        historyWrite = Task.detached(priority: .utility) { [history] in
            do {
                let directory = try history.save(entry, samples: samples)
                log("history: saved \(directory.lastPathComponent)")
                return directory
            } catch {
                log("history: not saved: \(error)")
                return nil
            }
        }
    }

    private func toggleHistory() {
        keepHistory.toggle()
        UserDefaults.standard.set(keepHistory, forKey: Self.keepHistoryKey)
        log(keepHistory ? "history: turned on, saving to \(history.directory.path)" : "history: turned off")
        menu.render()
    }

    /// The menu's switch for smart cleanup. It writes the same default `--llm-cleanup` and `defaults write` use,
    /// so the choice survives a relaunch, and asks the system right away whether the model is ready.
    private func toggleCleanup() {
        let turningOn: Bool
        if case .off = cleanupState { turningOn = true } else { turningOn = false }
        UserDefaults.standard.set(turningOn, forKey: Self.llmCleanupKey)
        cleanupState = turningOn ? .unavailable("not checked yet") : .off
        log(turningOn ? "LLM cleanup: turned on" : "LLM cleanup: turned off")
        refreshCleanup()
        menu.render()
    }

    private func loadEngine() async {
        log("loading \(engine.variant.id)")
        do {
            let (stats, seconds) = try await timed { try await engine.load() }
            // The first inference pays a one-off Core ML setup cost; pay it here, not on the first dictation.
            let (_, warmup) = try await timed { try await engine.transcribe(Array(repeating: 0, count: Int(targetSampleRate))) }
            log(String(format: "model ready in %.2fs (warm load %.2fs, warm-up inference %.0f ms)", seconds, stats.loadSeconds, warmup * 1000))
            send(.engineReady)
        } catch {
            send(.failed("model load failed: \(error)"))
        }
    }

    /// While cleanup is asked for but the model is not ready, asks again; a ready cleaner is kept.
    private func refreshCleanup() {
        guard case .unavailable(let previous) = cleanupState else { return }
        switch makeSystemCleaner() {
        case .ready(let cleaner):
            cleanupState = .ready(cleaner)
            log("LLM cleanup ready (on-device model prewarming)")
        case .unavailable(let reason):
            cleanupState = .unavailable(reason)
            if reason != previous { log("LLM cleanup unavailable: \(reason); dictations use the rule output until it is") }
        }
    }

    private func refreshAccessibility() {
        let granted = Permission.accessibility.isGranted
        guard granted != accessibilityGranted else { return }
        accessibilityGranted = granted
        log("accessibility \(granted ? "granted" : "revoked")")
        // A monitor added while untrusted is not guaranteed to start receiving events once trusted.
        hotkey.install()
        menu.render()
    }

    private func pollForAccessibility() {
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                refreshAccessibility()
                if accessibilityGranted { accessibilityPoll?.invalidate() }
            }
        }
    }
}

/// What the transcription task hands back to the main actor.
private struct TranscribedTake: Sendable {
    /// The exact samples Parakeet transcribed.
    let samples: [Float]
    let styled: StyledTarget
    let raw: String
    let formatted: String
    /// Nil when LLM cleanup was off.
    let cleanup: CleanupResult?
    let stopMs: Double
    let transcribeMs: Double
    let formatMs: Double

    var text: String { pasteText(cleanup?.text ?? formatted, style: styled.decision.style) }
}

/// Where a dictation goes and how it is written there.
struct StyledTarget: Sendable {
    let target: DictationTarget
    let decision: StyleDecision

    var menuLine: String { "Style: \(decision.style.name) (\(target.appName ?? target.bundleID ?? "unknown app"))" }
}

/// The LLM cleanup pass: off unless asked for, and once asked for, ready or waiting on this Mac.
enum CleanupState {
    case off
    case unavailable(String)
    case ready(any TranscriptCleaner)

    var cleaner: (any TranscriptCleaner)? {
        if case .ready(let cleaner) = self { cleaner } else { nil }
    }

    var menu: CleanupMenu {
        switch self {
        case .off: CleanupMenu(mark: .off, detail: nil, offersAppleIntelligenceSettings: false)
        case .ready: CleanupMenu(mark: .on, detail: nil, offersAppleIntelligenceSettings: false)
        case .unavailable(let reason):
            CleanupMenu(mark: .waiting, detail: "Waiting: \(reason)", offersAppleIntelligenceSettings: reason.contains("Apple Intelligence is off"))
        }
    }
}

/// What the menu shows for smart cleanup: a switch, and while it is switched on but not ready, why and what to do.
struct CleanupMenu {
    enum Mark { case off, on, waiting }
    let mark: Mark
    let detail: String?
    let offersAppleIntelligenceSettings: Bool
}

private func cleanupLogLine(_ outcome: CleanupOutcome) -> String {
    switch outcome {
    case .skipped: "cleanup: skipped (nothing for the model to do in this style)"
    case .accepted(let text): "cleaned: \(text)"
    case .rejected(let output, let reason): "cleanup fell back (\(reason))" + (output.map { "; llm said: \($0)" } ?? "")
    }
}

extension AppController {
    private func resolve(_ target: DictationTarget) -> StyledTarget {
        StyledTarget(target: target, decision: resolveStyle(for: target, overrides: styleOverrides))
    }

    private var styleLine: String { styled?.menuLine ?? "Style: chosen per app when you dictate" }
}

private func loadOverrides() -> [String: DictationStyle] {
    let (overrides, invalid) = loadStyleOverrides()
    if !invalid.isEmpty {
        log("styleOverrides: ignoring \(invalid.joined(separator: ", ")); styles are \(DictationStyle.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    return overrides
}

private func loadFormattingContext() -> FormattingContext {
    FormattingContext(skills: SkillCatalog.load(), slashCommands: SkillCatalog.claudeCodeSlashCommands)
}

private func measure<T>(_ body: () -> T) -> (T, Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let value = body()
    return (value, ProcessInfo.processInfo.systemUptime - start)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[yapn] \(message)\n".utf8))
}
