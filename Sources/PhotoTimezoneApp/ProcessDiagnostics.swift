import Darwin
import Foundation

/// Lightweight, process-local telemetry. One logical CPU core is 100%; the
/// ExifTool child is a separate process and is intentionally not conflated
/// with this App's own CPU and memory numbers.
@MainActor
final class ProcessDiagnostics: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var memoryBytes: UInt64?
    @Published private(set) var updatedAt: Date?

    private var samplingTask: Task<Void, Never>?
    private var previousCPUSeconds: Double?
    private var previousUptime: TimeInterval?

    func start() {
        guard samplingTask == nil else { return }
        sample()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.sample()
            }
        }
    }

    func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        previousCPUSeconds = nil
        previousUptime = nil
    }

    private func sample() {
        let uptime = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            let cpuSeconds = user + system
            if let previousCPUSeconds, let previousUptime, uptime > previousUptime {
                cpuPercent = max(0, (cpuSeconds - previousCPUSeconds) / (uptime - previousUptime) * 100)
            }
            previousCPUSeconds = cpuSeconds
            previousUptime = uptime
        } else {
            cpuPercent = nil
        }

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        memoryBytes = status == KERN_SUCCESS ? info.phys_footprint : nil
        updatedAt = Date()
    }
}
