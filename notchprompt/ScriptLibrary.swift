//
//  ScriptLibrary.swift
//  notchprompt
//
//  Named, saved scripts.
//
//  `ScriptFileIO` handles one file at a time through open/save panels, which is
//  the wrong shape for daily use — a teleprompter is something you open every
//  day, and hunting for a file each time is friction with no payoff.
//
//  Storage is a single JSON file in the app's Documents directory. Under the
//  App Sandbox that resolves to the app container, which is the only location
//  writable without user consent. A single file also means one atomic write and
//  no filename sanitisation or collision handling.
//

import Foundation
import Combine

struct SavedScript: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var text: String
    var updatedAt: Date

    var wordCount: Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Rough delivery time at a normal speaking pace.
    var estimatedSeconds: Int {
        Int((Double(wordCount) / 160.0) * 60.0)
    }

    var shortSummary: String {
        let words = wordCount
        guard words > 0 else { return "empty" }
        let minutes = estimatedSeconds / 60
        let seconds = estimatedSeconds % 60
        if minutes == 0 { return "\(words) words · ~\(seconds)s" }
        return "\(words) words · ~\(minutes)m \(String(format: "%02d", seconds))s"
    }
}

@MainActor
final class ScriptLibrary: ObservableObject {
    static let shared = ScriptLibrary()

    /// Most recently updated first.
    @Published private(set) var scripts: [SavedScript] = []
    @Published private(set) var lastError: String?

    private let storeURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter storeURL: injectable for tests; defaults to the app's
    ///   Documents directory.
    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? ScriptLibrary.defaultStoreURL()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        reload()
    }

    static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("notchprompt-scripts.json")
    }

    // MARK: - Persistence

    func reload() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            scripts = []
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try decoder.decode([SavedScript].self, from: data)
            scripts = decoded.sorted { $0.updatedAt > $1.updatedAt }
            lastError = nil
        } catch {
            // A corrupt library must not stop the app from launching; the
            // scripts are recoverable by hand and the failure is surfaced.
            scripts = []
            lastError = "Couldn't read the saved script library: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            let data = try encoder.encode(scripts)
            try data.write(to: storeURL, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = "Couldn't save the script library: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Mutation

    /// Save the given text as a new script, disambiguating a duplicate name.
    @discardableResult
    func save(name: String, text: String) -> SavedScript? {
        save(name: name, to: text)
    }

    @discardableResult
    func save(name: String, to text: String) -> SavedScript? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            lastError = "Nothing to save — the script is empty."
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = SavedScript(
            id: UUID(),
            name: uniqueName(trimmedName.isEmpty ? "Untitled script" : trimmedName),
            text: text,
            updatedAt: Date()
        )
        scripts.insert(script, at: 0)
        guard persist() else {
            scripts.removeAll { $0.id == script.id }
            return nil
        }
        return script
    }

    /// Overwrite a script's text, keeping its name and position in the recency
    /// order. Used to "save changes" on an already-saved script.
    func updateText(of script: SavedScript, to text: String) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Nothing to save — the script is empty."
            return
        }
        scripts[index].text = text
        scripts[index].updatedAt = Date()
        scripts.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func rename(_ script: SavedScript, to name: String) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != scripts[index].name else { return }

        // Keep names unique, but never collide with the script being renamed.
        var candidate = trimmed
        var counter = 2
        while scripts.contains(where: { $0.id != script.id && $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(trimmed) \(counter)"
            counter += 1
        }
        scripts[index].name = candidate
        persist()
    }

    func delete(_ script: SavedScript) {
        scripts.removeAll { $0.id == script.id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            scripts.indices.contains(index) ? scripts[index].id : nil
        }
        scripts.removeAll { ids.contains($0.id) }
        persist()
    }

    @discardableResult
    func duplicate(_ script: SavedScript) -> SavedScript? {
        save(name: "\(script.name) copy", text: script.text)
    }

    func script(named name: String) -> SavedScript? {
        scripts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func contains(textOf script: SavedScript) -> Bool {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return false }
        return scripts[index].text == script.text
    }

    var isEmpty: Bool { scripts.isEmpty }

    // MARK: - Helpers

    /// `Sales pitch` -> `Sales pitch 2` when that name is taken.
    private func uniqueName(_ desired: String) -> String {
        var candidate = desired
        var counter = 2
        while scripts.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(desired) \(counter)"
            counter += 1
        }
        return candidate
    }
}
