import Foundation

/// Resumes a continuation exactly once, whichever of several racing paths gets there first — typically
/// the work finishing versus a deadline firing. Later calls are no-ops.
public final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    public init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    public func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
