import XCTest
@testable import CoreLogic

/// Small deterministic generator (SplitMix64) so shuffle results are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class PlaybackQueueTests: XCTestCase {
    private func makeQueue(_ items: [Int] = [1, 2, 3, 4], at index: Int = 0) -> PlaybackQueue<Int> {
        var queue = PlaybackQueue<Int>()
        XCTAssertTrue(queue.start(items, at: index))
        return queue
    }

    // MARK: start / jump

    func testStartRejectsOutOfRangeIndex() {
        var queue = PlaybackQueue<Int>()
        XCTAssertFalse(queue.start([1, 2], at: 2))
        XCTAssertFalse(queue.start([], at: 0))
        XCTAssertNil(queue.current)
    }

    func testStartSetsCurrentAndUpcomingCount() {
        let queue = makeQueue([10, 20, 30], at: 1)
        XCTAssertEqual(queue.current, 20)
        XCTAssertEqual(queue.upcomingCount, 1)
    }

    func testJumpOnlyAcceptsValidPositions() {
        var queue = makeQueue([1, 2, 3])
        XCTAssertTrue(queue.jump(to: 2))
        XCTAssertEqual(queue.current, 3)
        XCTAssertFalse(queue.jump(to: 3))
        XCTAssertFalse(queue.jump(to: -1))
        XCTAssertEqual(queue.current, 3)
    }

    // MARK: advance / repeat

    func testManualAdvanceMovesForwardThenStopsAtEnd() {
        var queue = makeQueue([1, 2])
        XCTAssertEqual(queue.advance(automatic: false, repeatMode: .off), .changed)
        XCTAssertEqual(queue.current, 2)
        XCTAssertEqual(queue.advance(automatic: false, repeatMode: .off), .unchanged)
        XCTAssertEqual(queue.current, 2)
    }

    func testAutomaticAdvanceAtEndFinishesWithoutMovingIndex() {
        var queue = makeQueue([1, 2], at: 1)
        XCTAssertEqual(queue.advance(automatic: true, repeatMode: .off), .finished)
        XCTAssertEqual(queue.current, 2)
    }

    func testRepeatOneRestartsOnAutomaticEndButManualNextStillAdvances() {
        var queue = makeQueue([1, 2])
        XCTAssertEqual(queue.advance(automatic: true, repeatMode: .one), .restart)
        XCTAssertEqual(queue.current, 1)
        XCTAssertEqual(queue.advance(automatic: false, repeatMode: .one), .changed)
        XCTAssertEqual(queue.current, 2)
    }

    func testRepeatAllWrapsToTheFirstSongForAutomaticAndManualAdvance() {
        var queue = makeQueue([1, 2], at: 1)
        XCTAssertTrue(queue.canAdvance(repeatMode: .all))
        XCTAssertFalse(queue.canAdvance(repeatMode: .off))
        XCTAssertEqual(queue.advance(automatic: true, repeatMode: .all), .changed)
        XCTAssertEqual(queue.current, 1)
        XCTAssertTrue(queue.jump(to: 1))
        XCTAssertEqual(queue.advance(automatic: false, repeatMode: .all), .changed)
        XCTAssertEqual(queue.current, 1)
    }

    func testAdvanceAndCanAdvanceOnEmptyQueue() {
        var queue = PlaybackQueue<Int>()
        XCTAssertEqual(queue.advance(automatic: true, repeatMode: .all), .unchanged)
        XCTAssertFalse(queue.canAdvance(repeatMode: .all))
    }

    // MARK: previous

    func testPreviousRestartsAfterThreeSecondsAndAtTheFirstSong() {
        var queue = makeQueue([1, 2, 3], at: 1)
        XCTAssertEqual(queue.previous(elapsed: 3.1), .restart)
        XCTAssertEqual(queue.current, 2)
        XCTAssertEqual(queue.previous(elapsed: 3.0), .changed)
        XCTAssertEqual(queue.current, 1)
        XCTAssertEqual(queue.previous(elapsed: 0), .restart)
        XCTAssertEqual(queue.current, 1)
    }

    // MARK: editing

    func testInsertNextPlacesSongRightAfterCurrent() {
        var queue = makeQueue([1, 2, 3])
        queue.insertNext(9)
        XCTAssertEqual(queue.items, [1, 9, 2, 3])
        XCTAssertEqual(queue.current, 1)
    }

    func testInsertNextIntoEmptyQueueMakesItCurrent() {
        var queue = PlaybackQueue<Int>()
        queue.insertNext(5)
        XCTAssertEqual(queue.items, [5])
        XCTAssertEqual(queue.current, 5)
    }

    func testAppendAddsToTheEnd() {
        var queue = makeQueue([1, 2])
        queue.append(3)
        XCTAssertEqual(queue.items, [1, 2, 3])
        XCTAssertEqual(queue.upcomingCount, 2)
    }

    func testRemoveUpcomingRefusesPlayedCurrentAndOutOfRange() {
        var queue = makeQueue([1, 2, 3, 4], at: 1)
        XCTAssertFalse(queue.removeUpcoming(at: 0))
        XCTAssertFalse(queue.removeUpcoming(at: 1))
        XCTAssertFalse(queue.removeUpcoming(at: 9))
        XCTAssertTrue(queue.removeUpcoming(at: 3))
        XCTAssertEqual(queue.items, [1, 2, 3])
        XCTAssertEqual(queue.current, 2)
    }

    func testMoveUpcomingReordersOnlyUpcomingSongs() {
        var queue = makeQueue([1, 2, 3, 4, 5])
        XCTAssertTrue(queue.moveUpcoming(from: 3, to: 1))
        XCTAssertEqual(queue.items, [1, 4, 2, 3, 5])
        XCTAssertFalse(queue.moveUpcoming(from: 0, to: 2), "current song cannot be moved")
        XCTAssertFalse(queue.moveUpcoming(from: 2, to: 0), "cannot move before the current song")
        XCTAssertFalse(queue.moveUpcoming(from: 2, to: 9))
        XCTAssertEqual(queue.items, [1, 4, 2, 3, 5])
    }

    func testClearEmptiesQueue() {
        var queue = makeQueue()
        queue.clear()
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertNil(queue.current)
    }

    // MARK: shuffle (deterministic via injected generator)

    func testShuffleKeepsPlayedAndCurrentSongsInPlace() {
        var queue = makeQueue(Array(1...10), at: 3)
        var generator = SeededGenerator(seed: 42)
        queue.shuffleUpcoming(using: &generator)
        XCTAssertEqual(Array(queue.items.prefix(4)), [1, 2, 3, 4])
        XCTAssertEqual(queue.current, 4)
        XCTAssertEqual(Set(queue.items.dropFirst(4)), Set(5...10))
        XCTAssertEqual(queue.items.count, 10)
    }

    func testShuffleIsReproducibleForTheSameSeed() {
        var first = makeQueue(Array(1...20))
        var second = makeQueue(Array(1...20))
        var a = SeededGenerator(seed: 7)
        var b = SeededGenerator(seed: 7)
        first.shuffleUpcoming(using: &a)
        second.shuffleUpcoming(using: &b)
        XCTAssertEqual(first.items, second.items)
    }

    func testShuffleActuallyReordersForSomeSeed() {
        let original = Array(1...10)
        let reordered = (UInt64(1)...20).contains { seed in
            var queue = makeQueue(original)
            var generator = SeededGenerator(seed: seed)
            queue.shuffleUpcoming(using: &generator)
            return queue.items != original
        }
        XCTAssertTrue(reordered)
    }

    func testShuffleDoesNothingWithOneOrZeroUpcomingSongs() {
        var queue = makeQueue([1, 2])
        var generator = SeededGenerator(seed: 1)
        queue.shuffleUpcoming(using: &generator)
        XCTAssertEqual(queue.items, [1, 2])
        var empty = PlaybackQueue<Int>()
        empty.shuffleUpcoming(using: &generator)
        XCTAssertTrue(empty.items.isEmpty)
    }

    func testDefaultShufflePreservesTheSameSongs() {
        var queue = makeQueue(Array(1...30), at: 5)
        queue.shuffleUpcoming()
        XCTAssertEqual(queue.items.sorted(), Array(1...30))
        XCTAssertEqual(queue.current, 6)
    }
}
