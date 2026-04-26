import Foundation
import Combine

/// Internal event broadcaster. Backs three public observation surfaces:
/// `progressPublisher` (Combine), `progressStream` (AsyncStream), and
/// `addProgressListener(_:)` (callback). All three observe the same source.
internal final class ProgressBroadcaster: @unchecked Sendable {
    // Combine
    private let subject = PassthroughSubject<ProgressEvent, Never>()
    var publisher: AnyPublisher<ProgressEvent, Never> { subject.eraseToAnyPublisher() }

    // AsyncStream — one continuation per consumer
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ProgressEvent>.Continuation] = [:]

    // Callback — one entry per addProgressListener call
    private var callbacks: [UUID: @Sendable (ProgressEvent) -> Void] = [:]

    func emit(_ event: ProgressEvent) {
        subject.send(event)

        lock.lock()
        let conts = continuations.values
        let cbs = Array(callbacks.values)
        lock.unlock()

        for cont in conts { cont.yield(event) }
        for cb in cbs { cb(event) }
    }

    func makeStream() -> AsyncStream<ProgressEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    @discardableResult
    func addCallback(_ cb: @escaping @Sendable (ProgressEvent) -> Void) -> CancellationToken {
        let id = UUID()
        lock.lock()
        callbacks[id] = cb
        lock.unlock()

        return CancellationToken { [weak self] in
            self?.lock.lock()
            self?.callbacks.removeValue(forKey: id)
            self?.lock.unlock()
        }
    }
}

/// Caller-held token returned by `addProgressListener(_:)`. Drop or call
/// `.cancel()` to stop receiving events.
public final class CancellationToken: @unchecked Sendable {
    private let cancelClosure: @Sendable () -> Void
    private var cancelled = false
    private let lock = NSLock()

    internal init(cancel: @escaping @Sendable () -> Void) {
        self.cancelClosure = cancel
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !cancelled {
            cancelled = true
            cancelClosure()
        }
    }

    deinit {
        cancel()
    }
}
