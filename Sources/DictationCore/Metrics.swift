import Foundation

public func physFootprintBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

public func timed<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> (value: T, seconds: Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    let elapsed = start.duration(to: clock.now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return (value, seconds)
}

public enum PeakMemorySampler {
    public static func measure<T>(
        interval: Duration = .milliseconds(10),
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> (value: T, peakBytes: Int64) {
        let sampler = Task.detached {
            var peak = physFootprintBytes()
            while !Task.isCancelled {
                peak = max(peak, physFootprintBytes())
                try? await Task.sleep(for: interval)
            }
            return max(peak, physFootprintBytes())
        }
        do {
            let value = try await body()
            sampler.cancel()
            return (value, await sampler.value)
        } catch {
            sampler.cancel()
            throw error
        }
    }
}
