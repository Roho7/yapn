import AppKit
import DictationCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        // `--llm-cleanup`, or `defaults write dev.roho.dictation llmCleanup -bool YES` for `open build/Dictation.app`.
        let llmCleanup = arguments.contains("--llm-cleanup") || UserDefaults.standard.bool(forKey: "llmCleanup")
        // `--keep-history`, or `defaults write dev.roho.dictation keepHistory -bool YES`; the menu toggle writes the same default.
        let keepHistory = arguments.contains("--keep-history") || UserDefaults.standard.bool(forKey: AppController.keepHistoryKey)
        if arguments.contains("--notch-live") {
            NotchIndicator.runLive()
            return
        }
        if arguments.contains("--notch-demo") {
            NotchIndicator.runDemo()
            return
        }
        if let flag = arguments.firstIndex(of: "--selftest"), arguments.indices.contains(flag + 1) {
            let url = URL(fileURLWithPath: arguments[flag + 1])
            let paste = !arguments.contains("--no-paste")
            do {
                let controller = AppController(
                    audio: FileAudioSource(samples: try loadSamples(from: url)),
                    llmCleanup: llmCleanup, keepHistory: keepHistory, paste: paste
                )
                self.controller = controller
                controller.start(listenForHotkey: false)
                Task { await runSelfTest(controller, paste: paste) }
            } catch {
                log("selftest: cannot read \(url.path): \(error)")
                exit(2)
            }
            return
        }

        let recorder = AudioRecorder()
        let controller = AppController(audio: recorder, indicator: NotchIndicator(), llmCleanup: llmCleanup, keepHistory: keepHistory)
        recorder.onLevel = { [weak controller] level in
            Task { @MainActor in controller?.updateLevel(level) }
        }
        self.controller = controller
        controller.start(listenForHotkey: true)
        Task { await requestPermissions() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
