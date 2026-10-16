import Foundation

/// Runs items one at a time, in order: the next starts when the previous says it is `done` (L review 90 — one
/// rename panel at a time when a recovery pass salvages several recordings). A second `done` for the same item
/// is ignored.
@MainActor
public final class OneAtATimeQueue<Item> {
    private var waiting: [Item] = []
    private var running = false
    private let run: @MainActor (Item, _ done: @escaping @MainActor () -> Void) -> Void

    public init(run: @escaping @MainActor (Item, _ done: @escaping @MainActor () -> Void) -> Void) {
        self.run = run
    }

    public func enqueue(_ item: Item) {
        waiting.append(item)
        runNext()
    }

    private func runNext() {
        guard !running, !waiting.isEmpty else { return }
        running = true
        var finished = false
        run(waiting.removeFirst()) { [weak self] in
            guard !finished else { return }
            finished = true
            self?.running = false
            self?.runNext()
        }
    }
}
