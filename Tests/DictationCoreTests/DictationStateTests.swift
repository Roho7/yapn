import Testing
@testable import DictationCore

struct DictationStateTests {
    @Test func fullDictationRunsRecordTranscribeInsertBackToIdle() {
        var state = DictationState.idle
        var effects: [DictationEffect]

        (state, effects) = reduce(state, .hotkeyDown(at: 10.0))
        #expect(state == .recording(since: 10.0))
        #expect(effects == [.startRecording])

        (state, effects) = reduce(state, .hotkeyUp(at: 12.5))
        #expect(state == .transcribing)
        #expect(effects == [.stopAndTranscribe])

        (state, effects) = reduce(state, .transcribed("run /grill-me"))
        #expect(state == .inserting)
        #expect(effects == [.insert("run /grill-me")])

        (state, effects) = reduce(state, .inserted)
        #expect(state == .idle)
        #expect(effects == [])
    }

    @Test func pressShorterThanMinimumCancelsInsteadOfTranscribing() {
        let (short, shortEffects) = reduce(.recording(since: 10.0), .hotkeyUp(at: 10.29))
        #expect(short == .idle)
        #expect(shortEffects == [.cancelRecording])

        let (atLimit, limitEffects) = reduce(.recording(since: 10.0), .hotkeyUp(at: 10.3))
        #expect(atLimit == .transcribing)
        #expect(limitEffects == [.stopAndTranscribe])
    }

    @Test func emptyOrBlankTranscriptReturnsToIdleWithoutInserting() {
        let (empty, emptyEffects) = reduce(.transcribing, .transcribed(""))
        #expect(empty == .idle)
        #expect(emptyEffects == [])

        let (blank, blankEffects) = reduce(.transcribing, .transcribed("  \n"))
        #expect(blank == .idle)
        #expect(blankEffects == [])
    }

    @Test func hotkeyIsIgnoredWhileBusyOrLoading() {
        let (transcribing, e1) = reduce(.transcribing, .hotkeyDown(at: 5))
        #expect(transcribing == .transcribing)
        #expect(e1 == [])

        let (inserting, e2) = reduce(.inserting, .hotkeyDown(at: 5))
        #expect(inserting == .inserting)
        #expect(e2 == [])

        let (loading, e3) = reduce(.loading, .hotkeyDown(at: 5))
        #expect(loading == .loading)
        #expect(e3 == [])

        let (recording, e4) = reduce(.recording(since: 1), .hotkeyDown(at: 5))
        #expect(recording == .recording(since: 1))
        #expect(e4 == [])
    }

    @Test func strayReleaseWithoutPressIsIgnored() {
        let (state, effects) = reduce(.idle, .hotkeyUp(at: 3))
        #expect(state == .idle)
        #expect(effects == [])
    }

    @Test func failureWhileRecordingCancelsCaptureAndNextPressRecovers() {
        let (failed, effects) = reduce(.recording(since: 1), .failed("mic gone"))
        #expect(failed == .failed("mic gone"))
        #expect(effects == [.cancelRecording])

        let (retry, retryEffects) = reduce(failed, .hotkeyDown(at: 9))
        #expect(retry == .recording(since: 9))
        #expect(retryEffects == [.startRecording])
    }

    @Test func transcriptionFailureSurfacesReason() {
        let (state, effects) = reduce(.transcribing, .failed("model not loaded"))
        #expect(state == .failed("model not loaded"))
        #expect(effects == [])
    }

    @Test func engineReadyLeavesLoadingAndLateTranscriptIsIgnored() {
        let (ready, _) = reduce(.loading, .engineReady)
        #expect(ready == .idle)

        let (late, lateEffects) = reduce(.idle, .transcribed("stale"))
        #expect(late == .idle)
        #expect(lateEffects == [])
    }
}
