import Foundation

enum PlaybackRepeatMode: String, CaseIterable { case off, all, one }
enum QueueAdvance: Equatable { case changed, restart, finished, unchanged }

/// Value-only queue logic, shared by the iOS player and the regression tests.
struct PlaybackQueue<Item> {
    private(set) var items: [Item] = []
    private(set) var index = 0
    var current: Item? { items.indices.contains(index) ? items[index] : nil }
    var upcomingCount: Int { max(0, items.count - index - 1) }
    func canAdvance(repeatMode: PlaybackRepeatMode) -> Bool {
        current != nil && (upcomingCount > 0 || repeatMode == .all)
    }
    @discardableResult
    mutating func start(_ items: [Item], at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        self.items = items
        self.index = index
        return true
    }
    @discardableResult
    mutating func jump(to index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        self.index = index
        return true
    }
    mutating func advance(automatic: Bool, repeatMode: PlaybackRepeatMode) -> QueueAdvance {
        guard current != nil else { return .unchanged }
        if automatic && repeatMode == .one { return .restart }
        if upcomingCount > 0 { index += 1; return .changed }
        if repeatMode == .all { index = 0; return .changed }
        return automatic ? .finished : .unchanged
    }
    mutating func previous(elapsed: Double) -> QueueAdvance {
        guard current != nil else { return .unchanged }
        if elapsed > 3 || index == 0 { return .restart }
        index -= 1
        return .changed
    }
    mutating func insertNext(_ item: Item) {
        guard current != nil else { items = [item]; index = 0; return }
        items.insert(item, at: index + 1)
    }
    mutating func append(_ item: Item) { items.append(item) }
    mutating func shuffleUpcoming() {
        guard upcomingCount > 1 else { return }
        items = Array(items.prefix(index + 1)) + Array(items.dropFirst(index + 1)).shuffled()
    }
    @discardableResult
    mutating func removeUpcoming(at position: Int) -> Bool {
        guard items.indices.contains(position), position > index else { return false }
        items.remove(at: position)
        return true
    }
    @discardableResult
    mutating func moveUpcoming(from position: Int, to destination: Int) -> Bool {
        guard items.indices.contains(position), items.indices.contains(destination),
              position > index, destination > index else { return false }
        let item = items.remove(at: position)
        items.insert(item, at: destination)
        return true
    }
    mutating func clear() { items = []; index = 0 }
}
