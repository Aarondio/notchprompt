//
//  AnswerCache.swift
//  notchprompt
//
//  Caches AI answers to repeated questions.
//
//  Why: in a sales or interview context the same question comes up constantly
//  — "too expensive", "we already use a competitor", "tell me about yourself".
//  Re-asking costs money and, more importantly for live use, makes you wait.
//
//  Privacy: the in-memory cache costs nothing and is on by default. Writing
//  answers to disk is a separate, opt-in switch, because that leaves a record
//  of what was discussed on disk.
//

import Foundation

final class AnswerCache {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let question: String
        let answer: String
        let provider: String?
        let model: String?
        let createdAt: Date
        var hitCount: Int
    }

    static let shared = AnswerCache()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Least-recently-used first. Bounded by `maxEntries`.
    private var recency: [String] = []
    private var ttl: TimeInterval = 30 * 24 * 60 * 60
    private var maxEntries = 100
    private var persistenceEnabled = false
    private var hasLoadedFromDisk = false

    // MARK: - Keys

    /// Lowercases, strips punctuation, and collapses whitespace so that
    /// "What's your pricing?" and "whats your pricing" hit the same entry.
    ///
    /// Apostrophes are removed *before* tokenising. Splitting on them would turn
    /// "what's" into "what s", which then fails to match the unpunctuated
    /// "whats" and silently loses the cache hit.
    static func normalize(question: String, contextKey: String = "") -> String {
        func clean(_ value: String) -> String {
            value
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "") // typographic apostrophe
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        let base = clean(question)

        // Phase 4 will pass a coarse script-position bucket here so an answer
        // given during the pricing section is not reused in the close section.
        let context = clean(contextKey)
        return context.isEmpty ? base : "\(context)|\(base)"
    }

    /// Very short questions are too ambiguous to serve from cache.
    static func isCacheable(question: String, minimumCharacters: Int = 8) -> Bool {
        normalize(question: question).count >= minimumCharacters
    }

    // MARK: - Configuration

    func configure(ttl: TimeInterval, maxEntries: Int, persistenceEnabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.ttl = ttl
        self.maxEntries = max(1, maxEntries)
        let turnedOff = self.persistenceEnabled && !persistenceEnabled
        self.persistenceEnabled = persistenceEnabled
        if turnedOff {
            // User switched persistence off: remove the file we wrote earlier.
            try? FileManager.default.removeItem(at: Self.storeURL)
            try? FileManager.default.removeItem(at: Self.storeDirectory)
        }
        if persistenceEnabled { loadFromDiskLocked() } else { hasLoadedFromDisk = true }
        evictLocked()
    }

    // MARK: - Access

    func lookup(_ question: String, contextKey: String = "") -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        loadFromDiskLocked()

        let key = Self.normalize(question: question, contextKey: contextKey)
        guard var entry = entries[key] else { return nil }

        if ttl > 0, Date().timeIntervalSince(entry.createdAt) > ttl {
            removeLocked(key)
            return nil
        }

        entry.hitCount += 1
        entries[key] = entry
        touchLocked(key)
        return entry
    }

    @discardableResult
    func store(
        question: String,
        answer: String,
        provider: String?,
        model: String?,
        contextKey: String = ""
    ) -> Entry? {
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAnswer.isEmpty,
              Self.isCacheable(question: question) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        loadFromDiskLocked()

        let key = Self.normalize(question: question, contextKey: contextKey)
        let entry = Entry(
            id: key,
            question: question,
            answer: trimmedAnswer,
            provider: provider,
            model: model,
            createdAt: Date(),
            hitCount: 0
        )
        entries[key] = entry
        touchLocked(key)
        evictLocked()
        saveToDiskLocked()
        return entry
    }

    func remove(_ question: String) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(Self.normalize(question: question))
        saveToDiskLocked()
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        recency.removeAll()
        if persistenceEnabled {
            try? FileManager.default.removeItem(at: Self.storeURL)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Internals (all callers must hold the lock)

    private func loadFromDiskLocked() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true
        guard persistenceEnabled, let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([Entry].self, from: data) else { return }
        for entry in decoded {
            entries[entry.id] = entry
            touchLocked(entry.id)
        }
    }

    private func saveToDiskLocked() {
        guard persistenceEnabled, hasLoadedFromDisk else { return }
        let payload = recency.compactMap { entries[$0] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(payload) else { return }
        do {
            try FileManager.default.createDirectory(
                at: Self.storeDirectory,
                withIntermediateDirectories: true
            )
            try data.write(to: Self.storeURL, options: .atomic)
        } catch {
            // Disk cache is a convenience; failure must never break answering.
        }
    }

    private func touchLocked(_ key: String) {
        if let existing = recency.firstIndex(of: key) { recency.remove(at: existing) }
        recency.append(key)
    }

    private func removeLocked(_ key: String) {
        entries.removeValue(forKey: key)
        if let existing = recency.firstIndex(of: key) { recency.remove(at: existing) }
    }

    /// Enforce the size cap by dropping least-recently-used entries.
    private func evictLocked() {
        while recency.count > maxEntries, let oldest = recency.first {
            recency.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    // MARK: - Paths

    private static var storeDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("notch.notchprompt", isDirectory: true)
    }

    private static var storeURL: URL {
        storeDirectory.appendingPathComponent("answer-cache.json")
    }
}
