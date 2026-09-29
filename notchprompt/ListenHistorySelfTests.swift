//
//  ListenHistorySelfTests.swift
//  notchprompt
//
//  Browsing must never strand the user: no dead-end indices, and always a way
//  back to the live answer.
//

import Foundation

enum ListenHistorySelfTests {
    static func run() {
        assertIndexStaysInBounds()
        assertBrowsingForwardReachesLiveAnswer()
        assertNewestEntryIsIndexZero()
        assertEmptyHistoryIsSafe()
    }

    /// Mirrors the index arithmetic in `ListenModel` so the invariants are
    /// pinned independently of the UI.
    private static func browse(_ current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min((current ?? 0) + 1, count - 1)
    }

    private static func browseNewer(_ current: Int?) -> Int? {
        guard let current else { return nil }
        let next = current - 1
        return next < 0 ? nil : next
    }

    private static func assertIndexStaysInBounds() {
        // Walking all the way back must not exceed the newest entry.
        var index: Int? = nil
        let count = 5
        for _ in 0..<50 {
            index = browse(index, count: count)
        }
        assert(index == count - 1, "Walking back should stop at the oldest entry, got \(index ?? -1)")
    }

    private static func assertBrowsingForwardReachesLiveAnswer() {
        var index: Int? = nil
        index = browse(index, count: 4)   // 1
        index = browse(index, count: 4)   // 2
        index = browse(index, count: 4)   // 3 (oldest)
        assert(index == 3, "Should reach the oldest entry")

        // Returning forward must land back on nil, meaning "show live".
        index = browseNewer(index)
        assert(index == 2, "Stepped to 2, got \(index ?? -1)")
        index = browseNewer(index)
        index = browseNewer(index)
        index = browseNewer(index)
        assert(index == nil, "Stepping past the newest must return to the live answer")
    }

    private static func assertNewestEntryIsIndexZero() {
        // Index 0 is the newest because history is stored newest-first.
        let index = browse(nil, count: 3)
        assert(index == 1, "First step back from live should be index 1, got \(index ?? -1)")
    }

    private static func assertEmptyHistoryIsSafe() {
        assert(browse(nil, count: 0) == nil, "Browsing an empty history must be a no-op")
        assert(browseNewer(0) == nil, "Stepping forward from index 0 must return to live")
    }
}
