import Foundation

/// A bounded, lossless bridge from the engine thread to one async UI consumer.
/// A full channel suspends the producer on a condition (not the main actor).
/// Closing wakes blocked producers even if queued events were never consumed.
public final class BoundedJobEvents: @unchecked Sendable {
    public let events: AsyncStream<JobEvent>
    private let continuation: AsyncStream<JobEvent>.Continuation
    private let condition = NSCondition()
    private let capacity: Int
    private var outstanding = 0
    private var closed = false

    public init(capacity: Int = 64) {
        precondition(capacity > 0)
        self.capacity = capacity
        let pair = AsyncStream<JobEvent>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        events = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in self?.markClosed() }
    }

    public func send(_ event: JobEvent) {
        condition.lock()
        while outstanding >= capacity && !closed { condition.wait() }
        guard !closed else { condition.unlock(); return }
        outstanding += 1
        condition.unlock()
        // Never hold the condition while yielding: termination callbacks may
        // run synchronously and need the same condition to release producers.
        switch continuation.yield(event) {
        case .enqueued: break
        case .terminated: acknowledge()
        case .dropped:
            acknowledge(); close() // Violated consumer protocol: no silent partial success.
        @unknown default: acknowledge(); close()
        }
    }

    public func acknowledge() {
        condition.lock()
        outstanding = max(0, outstanding - 1)
        condition.signal()
        condition.unlock()
    }
    public func finish() { continuation.finish() }
    public func close() { markClosed(); continuation.finish() }
    private func markClosed() {
        condition.lock(); closed = true; condition.broadcast(); condition.unlock()
    }
}
