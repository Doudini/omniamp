import Foundation

/// Notification observers that are removed when their owner goes away. NotificationCenter allows removing them
/// from any thread, so a main-actor object (a window, a view) can hold them without a deinit of its own: a deinit
/// isn't tied to the main thread, and asserting it is would crash if the last reference ever went elsewhere.
final class Observers: @unchecked Sendable {   // the tokens only change under the lock
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
