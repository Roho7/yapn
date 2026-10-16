import DictationCore
import Foundation

struct Take {
    let samples: [Float]
    var seconds: Double { Double(samples.count) / targetSampleRate }
}

enum CaptureOutcome {
    case kept(Take)
    case skipped
    case quit
}

/// One push-to-talk take driven from the terminal, which cannot see key release:
/// Enter starts, Enter stops. With `review` the take can be replayed, redone or skipped before it is kept.
struct CaptureFlow {
    private enum Phase {
        case ready
        case recording
        case review(Take)
        case done(CaptureOutcome)
    }

    let recorder: AudioRecorder
    let readyHint: String
    let review: Bool

    func run() throws -> CaptureOutcome {
        var phase = Phase.ready
        while true {
            switch phase {
            case .ready:
                print(readyHint)
                switch readInput() {
                case "": try recorder.start(); print("recording... Enter to stop"); phase = .recording
                case "s" where review: phase = .done(.skipped)
                case "q", nil: phase = .done(.quit)
                default: break
                }
            case .recording:
                _ = readLine()
                let take = Take(samples: recorder.stop())
                print(String(format: "%.1fs recorded", take.seconds))
                phase = review ? .review(take) : .done(.kept(take))
            case .review(let take):
                print("Enter keep and next, r re-record, p play back, s skip, q quit")
                switch readInput() {
                case "": phase = .done(.kept(take))
                case "r": phase = .ready
                case "p": try play(take)
                case "s": phase = .done(.skipped)
                case "q", nil: phase = .done(.quit)
                default: break
                }
            case .done(let outcome):
                return outcome
            }
        }
    }

    private func readInput() -> String? {
        readLine().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private func play(_ take: Take) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-playback-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWAV(take.samples, to: url)
        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = [url.path]
        try afplay.run()
        afplay.waitUntilExit()
    }
}

func requireMicrophone() async throws {
    guard await AudioRecorder.requestAccess() else { throw AudioRecorderError.microphoneDenied }
}
