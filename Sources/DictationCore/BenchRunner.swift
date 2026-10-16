import Foundation

public func runBenchmark(
    variants: [EngineVariant],
    clips: [Clip],
    vocab: [String],
    log: (String) -> Void
) async throws -> RunResults {
    let startedAt = Date()
    let samples = try clips.map { try loadSamples(from: $0.audioURL) }
    var runs: [EngineRun] = []

    for variant in variants {
        let engine = makeEngine(variant, vocab: vocab)
        log("[\(variant.id)] loading")
        let load = try await engine.load()
        log("[\(variant.id)] loaded in \(String(format: "%.2f", load.loadSeconds))s")

        var results: [ClipResult] = []
        do {
            for (index, clip) in clips.enumerated() {
                let clipSamples = samples[index]
                let (timedResult, peak) = try await PeakMemorySampler.measure {
                    try await timed { try await engine.transcribe(clipSamples) }
                }
                results.append(ClipResult(
                    promptID: clip.prompt.id,
                    transcript: timedResult.value,
                    latencySeconds: timedResult.seconds,
                    audioSeconds: Double(clipSamples.count) / targetSampleRate,
                    peakMemoryBytes: peak,
                    isCold: index == 0
                ))
                log("[\(variant.id)] \(index + 1)/\(clips.count) \(String(format: "%.0f", timedResult.seconds * 1000))ms")
            }
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()
        runs.append(EngineRun(variant: variant, load: load, clips: results))
    }

    return RunResults(startedAt: startedAt, hardware: hardwareDescription(), prompts: clips.map(\.prompt), runs: runs)
}

public func hardwareDescription() -> String {
    let cpu = sysctlString("machdep.cpu.brand_string") ?? "unknown CPU"
    let memory = sysctlInt64("hw.memsize").map { "\($0 / 1_073_741_824) GB RAM" } ?? "unknown RAM"
    return "\(cpu), \(memory), \(ProcessInfo.processInfo.operatingSystemVersionString)"
}

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func sysctlInt64(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}
