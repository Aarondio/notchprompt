//
//  SpeechLocaleSelfTests.swift
//  notchprompt
//
//  The locale list is what fixes a real defect — recognition used to be pinned
//  to en-US regardless of the user's choice. These pin the resolution rules,
//  especially that an unlisted-but-valid code survives a round trip instead of
//  silently resetting to the default.
//

import Foundation

enum SpeechLocaleSelfTests {
    static func run() {
        assertSystemDefaultHasEmptyIdentifier()
        assertCommonLocalesAreUniqueAndWellFormed()
        assertResolveMapsListedLocales()
        assertResolveKeepsUnknownButValidCode()
        assertResolveIsCaseInsensitive()
        assertResolveTrimsWhitespace()
        assertEveryListedLocaleIsWellFormed()
    }

    private static func assertSystemDefaultHasEmptyIdentifier() {
        assert(
            SpeechLocale.systemDefault.id.isEmpty,
            "System default must use an empty identifier so it is distinguishable"
        )
        assert(
            SpeechLocale.all.first?.id == "",
            "System default should be offered first"
        )
    }

    private static func assertCommonLocalesAreUniqueAndWellFormed() {
        let ids = SpeechLocale.common.map(\.id)
        assert(Set(ids).count == ids.count, "Duplicate locale ids: \(ids)")

        let names = SpeechLocale.common.map(\.name)
        assert(Set(names).count == names.count, "Duplicate locale display names")

        for locale in SpeechLocale.common {
            assert(!locale.id.isEmpty, "Locale \(locale.name) has an empty id")
            assert(!locale.name.isEmpty, "Locale \(locale.id) has an empty name")
        }
    }

    private static func assertResolveMapsListedLocales() {
        for locale in SpeechLocale.common {
            let resolved = SpeechLocale.resolve(locale.id)
            assert(resolved.id == locale.id, "\(locale.id) should resolve to itself, got \(resolved.id)")
        }
    }

    private static func assertResolveKeepsUnknownButValidCode() {
        // A language not in the curated list must not reset to en-US; that was
        // the original defect.
        let resolved = SpeechLocale.resolve("is-IS")
        assert(resolved.id == "is-IS", "An unlisted code should be preserved, got \(resolved.id)")
    }

    private static func assertResolveIsCaseInsensitive() {
        assert(SpeechLocale.resolve("EN-us").id == "en-US", "Case should not matter")
        assert(SpeechLocale.resolve("DE-de").id == "de-DE", "Case should not matter")
    }

    private static func assertResolveTrimsWhitespace() {
        assert(SpeechLocale.resolve("  en-GB  ").id == "en-GB", "Surrounding whitespace should be trimmed")
        assert(SpeechLocale.resolve("   ").id.isEmpty, "Whitespace-only should resolve to system default")
    }

    private static func assertEveryListedLocaleIsWellFormed() {
        // BCP-47 shape check: language[-REGION][-Script]
        let pattern = "^[A-Za-z]{2,3}(-[A-Za-z]{4})?(-([A-Za-z]{2}|[0-9]{3}))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for locale in SpeechLocale.common {
            let range = NSRange(locale.id.startIndex..<locale.id.endIndex, in: locale.id)
            let matches = regex.numberOfMatches(in: locale.id, range: range)
            assert(matches == 1, "Locale id \"\(locale.id)\" is not a well-formed BCP-47 tag")
        }
    }
}
