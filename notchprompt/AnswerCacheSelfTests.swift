//
//  AnswerCacheSelfTests.swift
//  notchprompt
//
//  Checks for key normalization and the LRU/TTL eviction rules. Uses an
//  in-memory cache (persistence off) so nothing touches disk.
//

import Foundation

enum AnswerCacheSelfTests {
    static func run() {
        assertNormalizationStripsPunctuationAndCase()
        assertNormalizationCollapsesWhitespace()
        assertContextKeySeparatesEntries()
        assertShortQuestionsAreNotCacheable()
        assertLookupReturnsStoredAnswer()
        assertLookupUpdatesRecency()
        assertEvictionDropsLeastRecentlyUsed()
        assertExpiryRemovesEntry()
        assertRemoveAndClearWork()
        assertQuoteRoundTrips()
        assertLegacyEntriesWithoutQuoteStillDecode()
    }

    /// Regression: a cached answer used to lose its script quote, so recall and
    /// cache hits either showed no Jump button or jumped to the *previous*
    /// answer's line.
    private static func assertQuoteRoundTrips() {
        let cache = makeCache()
        cache.store(
            question: "what is your pricing",
            answer: "Fifty a seat per month.",
            provider: "DeepSeek",
            model: "deepseek-chat",
            quote: "our annual plan is fifty a seat"
        )
        let hit = cache.lookup("what is your pricing")
        assert(hit != nil, "Precondition: the entry should be cached")
        assert(
            hit?.quote == "our annual plan is fifty a seat",
            "The quote must survive the cache round trip, got \(String(describing: hit?.quote))"
        )

        // An answer with no quote must store nil rather than inheriting one.
        cache.store(
            question: "do you have sso here",
            answer: "Yes, SAML and SCIM.",
            provider: "DeepSeek",
            model: "deepseek-chat"
        )
        let noQuote = cache.lookup("do you have sso here")
        assert(
            noQuote?.quote == nil,
            "An answer with no quote must store nil, got \(String(describing: noQuote?.quote))"
        )
    }

    /// Adding `quote` to a persisted `Codable` struct must not orphan cache files
    /// written by an earlier build.
    private static func assertLegacyEntriesWithoutQuoteStillDecode() {
        let legacy = """
        [{"id":"what is your pricing","question":"What is your pricing?",
          "answer":"Fifty a seat.","provider":"OpenAI","model":"gpt-4o-mini",
          "createdAt":"2026-01-01T00:00:00Z","hitCount":0}]
        """
        guard let data = legacy.data(using: .utf8) else {
            assertionFailure("Could not build the legacy payload")
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([AnswerCache.Entry].self, from: data) else {
            assertionFailure("A cache file written before `quote` existed must still decode")
            return
        }
        assert(decoded.count == 1, "Expected one legacy entry, got \(decoded.count)")
        assert(
            decoded.first?.quote == nil,
            "A legacy entry should decode with no quote, got \(String(describing: decoded.first?.quote))"
        )
        assert(
            decoded.first?.answer == "Fifty a seat.",
            "Legacy entry content must be preserved"
        )
    }

    private static func makeCache(maxEntries: Int = 100, ttl: TimeInterval = 0) -> AnswerCache {
        let cache = AnswerCache()
        cache.configure(ttl: ttl, maxEntries: maxEntries, persistenceEnabled: false)
        return cache
    }

    // MARK: - Normalization

    private static func assertNormalizationStripsPunctuationAndCase() {
        let a = AnswerCache.normalize(question: "What's your pricing?")
        let b = AnswerCache.normalize(question: "whats your pricing")
        let c = AnswerCache.normalize(question: "  WHAT'S your pricing!!  ")
        assert(a == "whats your pricing", "Unexpected normalization: \(a)")
        assert(a == b, "Punctuation should not change the key")
        assert(a == c, "Case and padding should not change the key")
    }

    private static func assertNormalizationCollapsesWhitespace() {
        let a = AnswerCache.normalize(question: "how   much   is it")
        let b = AnswerCache.normalize(question: "how much is it")
        assert(a == b, "Repeated whitespace should collapse: \(a)")
    }

    private static func assertContextKeySeparatesEntries() {
        // Phase 4 will use a script-position bucket here; the same question in
        // two different sections must not collide.
        let pricing = AnswerCache.normalize(question: "what is the price", contextKey: "40")
        let close = AnswerCache.normalize(question: "what is the price", contextKey: "90")
        assert(pricing != close, "Different context keys must produce different cache keys")
    }

    private static func assertShortQuestionsAreNotCacheable() {
        assert(!AnswerCache.isCacheable(question: "yes"), "Very short questions must not be cached")
        assert(!AnswerCache.isCacheable(question: "ok"), "Very short questions must not be cached")
        assert(AnswerCache.isCacheable(question: "what is your pricing"), "Real questions should be cacheable")
    }

    // MARK: - Store / lookup

    private static func assertLookupReturnsStoredAnswer() {
        let cache = makeCache()
        cache.store(question: "What is your pricing?", answer: "Fifty a seat.", provider: "OpenAI", model: "gpt-4o-mini")

        // Punctuation and casing differences must still hit.
        let hit = cache.lookup("  WHAT IS YOUR PRICING!! ")
        assert(hit != nil, "A differently-punctuated repeat should hit")
        assert(hit?.answer == "Fifty a seat.", "Unexpected answer: \(hit?.answer ?? "nil")")
        assert(hit?.provider == "OpenAI", "Provider should be retained for display")

        assert(cache.lookup("something entirely different") == nil, "Unrelated questions must miss")

        // Known limitation, recorded deliberately: normalization is lexical, not
        // semantic. A contraction and its spelled-out form are different keys.
        // In practice the recognizer is consistent for a given phrasing, so this
        // costs a missed hit rather than a wrong answer.
        assert(
            cache.lookup("whats your pricing") == nil,
            "Contraction vs spelled-out forms are intentionally distinct keys"
        )
    }

    private static func assertLookupUpdatesRecency() {
        let cache = makeCache()
        cache.store(question: "what is your pricing", answer: "A", provider: nil, model: nil)
        cache.store(question: "how long is the contract", answer: "B", provider: nil, model: nil)
        cache.store(question: "do you have sso", answer: "C", provider: nil, model: nil)

        // Touch the first so it is no longer the least recently used.
        let first = cache.lookup("what is your pricing")
        assert(first?.hitCount == 1, "Hit count should increment, got \(first?.hitCount ?? -1)")
    }

    private static func assertEvictionDropsLeastRecentlyUsed() {
        let cache = makeCache(maxEntries: 2)
        cache.store(question: "first question here", answer: "1", provider: nil, model: nil)
        cache.store(question: "second question here", answer: "2", provider: nil, model: nil)

        // "first" becomes most-recently-used, so "second" is now the LRU victim.
        _ = cache.lookup("first question here")
        cache.store(question: "third question here", answer: "3", provider: nil, model: nil)

        assert(cache.count == 2, "Cache should respect its size cap, got \(cache.count)")
        assert(cache.lookup("first question here") != nil, "Recently used entry should survive")
        assert(cache.lookup("second question here") == nil, "Least recently used entry should be evicted")
    }

    private static func assertExpiryRemovesEntry() {
        // A zero TTL expires everything immediately.
        let cache = makeCache(ttl: 0.001)
        cache.store(question: "what is your pricing", answer: "A", provider: nil, model: nil)
        Thread.sleep(forTimeInterval: 0.01)
        assert(cache.lookup("what is your pricing") == nil, "Expired entries should not be served")
    }

    private static func assertRemoveAndClearWork() {
        let cache = makeCache()
        cache.store(question: "what is your pricing", answer: "A", provider: nil, model: nil)
        cache.store(question: "how long is the contract", answer: "B", provider: nil, model: nil)
        assert(cache.count == 2, "Expected two entries, got \(cache.count)")

        cache.remove("what is your pricing")
        assert(cache.count == 1, "Remove should drop exactly one entry")
        assert(cache.lookup("what is your pricing") == nil, "Removed entry should be gone")

        cache.clear()
        assert(cache.count == 0, "Clear should empty the cache")
    }
}
