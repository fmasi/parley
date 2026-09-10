/// Shared helpers for the test target.

/// Carries a non-Sendable value across a thread or actor boundary in a test.
final class Carry<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
