// Internal/AsyncSemaphore.swift
//
// A simple counting semaphore that's safe to await across suspension points.
// `value: 1` makes it a mutex; multiple `wait()`s queue up and resume in FIFO.
//
// Used by `FoundationHandlers` to serialize concurrent `LanguageModelSession`
// inference calls (`respond(to:)` / `streamResponse(to:)`). An NSLock around
// an `await` would deadlock because it isn't async-aware; we need a
// continuation-based async semaphore instead.

import Foundation

final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int = 1) { self.value = value }

    /// Try to take a permit synchronously without crossing a suspension
    /// point. Returns `nil` if a permit was acquired and the caller can
    /// proceed; returns a non-nil "register continuation" closure when the
    /// caller must instead `await` to be resumed by a future `signal()`.
    /// Splitting the NSLock manipulation into this sync helper keeps the
    /// lock from being touched inside an `async` context — NSLock is not
    /// async-safe (warning becomes an error in Swift 6).
    private func tryAcquireOrRegister() -> ((CheckedContinuation<Void, Never>) -> Void)? {
        lock.lock()
        if value > 0 {
            value -= 1
            lock.unlock()
            return nil
        }
        // Returning the locked-state register hook: caller stashes the
        // continuation, then we drop the lock. This preserves FIFO ordering
        // because a concurrent `signal()` blocks on the same NSLock until
        // the continuation is appended.
        return { [self] cont in
            waiters.append(cont)
            lock.unlock()
        }
    }

    func wait() async {
        guard let register = tryAcquireOrRegister() else { return }
        await withCheckedContinuation { cont in
            register(cont)
        }
    }

    func signal() {
        lock.lock()
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            lock.unlock()
            cont.resume()
        } else {
            value += 1
            lock.unlock()
        }
    }
}
