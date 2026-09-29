//
//  ScriptLibrarySelfTests.swift
//  notchprompt
//
//  The library is the user's own content, so the properties that matter are
//  durability and safety: a failed write must not corrupt the in-memory list,
//  and destructive operations must not affect unrelated scripts.
//
//  Each test builds its own library over a temporary file, so they neither
//  touch nor depend on the real one.
//

import Foundation

@MainActor
enum ScriptLibrarySelfTests {
    static func run() {
        assertSaveAddsAndPersists()
        assertReloadRestoresFromDisk()
        assertDuplicateNamesAreDisambiguated()
        assertRenameRejectsBlankAndKeepsUnique()
        assertEmptyScriptIsRejected()
        assertUpdateKeepsIdentityAndBumpsDate()
        assertDeleteRemovesOnlyTheTarget()
        assertCorruptFileDoesNotCrash()
        assertSaveFailureLeavesListUnchanged()
        assertSortingIsMostRecentFirst()
    }

    /// A library backed by a throwaway file.
    private static func makeLibrary() -> (ScriptLibrary, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-library-tests-\(UUID().uuidString).json")
        return (ScriptLibrary(storeURL: url), url)
    }

    private static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Basics

    private static func assertSaveAddsAndPersists() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        let saved = library.save(name: "Sales pitch", text: "Hello there.")
        assert(saved != nil, "Saving should succeed")
        assert(library.scripts.count == 1, "Expected one script, got \(library.scripts.count)")
        assert(library.script(named: "Sales pitch") != nil, "Script should be findable by name")
    }

    private static func assertReloadRestoresFromDisk() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        library.save(name: "Pitch", text: "Opening line.")
        library.save(name: "Objections", text: "Too expensive.")

        // A fresh instance over the same file must see both.
        let reopened = ScriptLibrary(storeURL: url)
        assert(reopened.scripts.count == 2, "Expected two scripts after reload, got \(reopened.scripts.count)")
        assert(
            reopened.script(named: "Objections")?.text == "Too expensive.",
            "Reloaded text should match"
        )
    }

    private static func assertDuplicateNamesAreDisambiguated() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        library.save(name: "Pitch", text: "First.")
        let second = library.save(name: "Pitch", text: "Second.")
        // Case-insensitive collision: the display name is kept as the user
        // typed it, but the stored key must still be unique.
        let third = library.save(name: "pitch", text: "Third.")

        assert(second?.name == "Pitch 2", "Expected a disambiguated name, got \(second?.name ?? "nil")")
        assert(third?.name == "pitch 3", "Case-insensitive collision should disambiguate, got \(third?.name ?? "nil")")
        let names = library.scripts.map(\.name)
        assert(Set(names.map { $0.lowercased() }).count == names.count, "Stored names must be unique: \(names)")
    }

    private static func assertRenameRejectsBlankAndKeepsUnique() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        guard let first = library.save(name: "One", text: "a"),
              let second = library.save(name: "Two", text: "b") else {
            assert(false, "Setup failed")
            return
        }

        library.rename(first, to: "   ")
        assert(library.script(named: "One") != nil, "A blank rename should be ignored")

        library.rename(first, to: "Two")
        assert(library.script(named: "Two") != nil, "The original Two should survive")
        assert(
            library.scripts.contains { $0.id == first.id && $0.name == "Two 2" },
            "Renaming onto a taken name should disambiguate"
        )
        _ = second
    }

    private static func assertEmptyScriptIsRejected() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        assert(library.save(name: "Blank", text: "   \n  ") == nil, "An empty script should not be saved")
        assert(library.scripts.isEmpty, "Nothing should have been added")
        assert(library.lastError != nil, "An error should be surfaced")
    }

    private static func assertUpdateKeepsIdentityAndBumpsDate() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        guard let saved = library.save(name: "Draft", text: "Old text.") else {
            assert(false, "Setup failed")
            return
        }
        let originalID = saved.id
        let originalDate = saved.updatedAt

        Thread.sleep(forTimeInterval: 0.01)
        library.updateText(of: saved, to: "New text.")

        let updated = library.scripts.first { $0.id == originalID }
        assert(updated != nil, "The script should still exist after update")
        assert(updated?.text == "New text.", "Text should be replaced")
        assert(updated?.name == "Draft", "Name should be preserved on update")
        assert(
            updated.map { $0.updatedAt > originalDate } ?? false,
            "updatedAt should advance so recency ordering is correct"
        )
    }

    private static func assertDeleteRemovesOnlyTheTarget() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        guard let keep = library.save(name: "Keep", text: "stays"),
              let drop = library.save(name: "Drop", text: "goes") else {
            assert(false, "Setup failed")
            return
        }

        library.delete(drop)
        assert(library.scripts.count == 1, "Expected one remaining, got \(library.scripts.count)")
        assert(library.scripts.contains { $0.id == keep.id }, "The wrong script was removed")

        // And the deletion must survive a reload.
        let reopened = ScriptLibrary(storeURL: url)
        assert(reopened.scripts.count == 1, "Deletion should persist")
        assert(reopened.scripts.first?.name == "Keep", "The surviving script should still be there")
    }

    // MARK: - Resilience

    private static func assertCorruptFileDoesNotCrash() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-library-corrupt-\(UUID().uuidString).json")
        defer { cleanUp(url) }

        // Deliberately invalid JSON.
        try? Data("{ this is not valid json".utf8).write(to: url)

        let library = ScriptLibrary(storeURL: url)
        assert(library.scripts.isEmpty, "A corrupt file should yield an empty list, not a crash")
        assert(library.lastError != nil, "A corrupt file should surface an error")

        // And the library must still be usable afterwards.
        assert(library.save(name: "Fresh", text: "recovered") != nil, "Should still be writable after a corrupt read")
    }

    private static func assertSaveFailureLeavesListUnchanged() {
        // Point at a path that cannot be a writable file: a directory.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-library-dir-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = ScriptLibrary(storeURL: directory)
        let before = library.scripts.count

        let result = library.save(name: "Doomed", text: "content")
        assert(result == nil, "Saving to an unwritable path should fail")
        assert(
            library.scripts.count == before,
            "A failed save must not leave a phantom entry in the in-memory list"
        )
        assert(library.lastError != nil, "A failed save should surface an error")
    }

    private static func assertSortingIsMostRecentFirst() {
        let (library, url) = makeLibrary()
        defer { cleanUp(url) }

        library.save(name: "Oldest", text: "1")
        Thread.sleep(forTimeInterval: 0.01)
        library.save(name: "Middle", text: "2")
        Thread.sleep(forTimeInterval: 0.01)
        library.save(name: "Newest", text: "3")

        assert(
            library.scripts.map(\.name) == ["Newest", "Middle", "Oldest"],
            "Expected recency order, got \(library.scripts.map(\.name))"
        )
    }
}
