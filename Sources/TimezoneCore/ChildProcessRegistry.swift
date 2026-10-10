import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Only processes launched by this App. Shutdown prevents a preview from
/// launching another tool after application termination has begun.
public final class ChildProcessRegistry: @unchecked Sendable {
    public static let shared = ChildProcessRegistry()
    private let lock = NSLock()
    private var children: [ObjectIdentifier: Process] = [:]
    private var closing = false
    public init() {}

    public func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw CancellationError() }
        try process.run()
        children[ObjectIdentifier(process)] = process
    }

    public func finished(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        children.removeValue(forKey: ObjectIdentifier(process))
    }

    public func shutdown() {
        lock.lock()
        closing = true
        let active = Array(children.values)
        children.removeAll()
        lock.unlock()
        for process in active where process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while active.contains(where: { $0.isRunning }) && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for process in active where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        for process in active { process.waitUntilExit() }
    }
}
