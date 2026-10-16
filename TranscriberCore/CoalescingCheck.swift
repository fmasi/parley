import Foundation

/// Runs one async check at a time (L round 6). A caller arriving while a check runs does not answer at
/// once: it queues ONE re-run — `merge` keeps the most urgent trigger — and waits for the running check
/// and that re-run, so its answer reflects them. The permission repair check uses it: a new permission
/// alarm that joins the record-start check (waiting on a macOS prompt) must not report "no window" while
/// that check is about to open one.
@MainActor
public final class CoalescingCheck<Trigger: Equatable & Sendable> {
    private let perform: @MainActor (Trigger) async -> Void
    private let merge: @MainActor (Trigger?, Trigger) -> Trigger
    private var running: Task<Void, Never>?
    private var pending: Trigger?

    /// `merge(pending, incoming)`: the trigger the queued re-run should use.
    public init(perform: @escaping @MainActor (Trigger) async -> Void,
                merge: @escaping @MainActor (Trigger?, Trigger) -> Trigger) {
        self.perform = perform
        self.merge = merge
    }

    public func run(_ trigger: Trigger) async {
        if let running {
            pending = merge(pending, trigger)
            await running.value   // covers the queued re-run: the running task loops over it
            return
        }
        let task = Task { @MainActor in
            var next: Trigger? = trigger
            while let current = next {
                await self.perform(current)
                next = self.pending
                self.pending = nil
            }
            self.running = nil
        }
        running = task
        await task.value
    }
}
