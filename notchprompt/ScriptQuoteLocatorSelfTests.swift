//
//  ScriptQuoteLocatorSelfTests.swift
//  notchprompt
//
//  Spike coverage for Phase 5. The two things that decide whether jumping to
//  a quote is feasible at all: can we FIND the quote in a script the model
//  paraphrased, and does a character index round-trip back to a sensible
//  scroll position?
//

import Foundation
import CoreGraphics

enum ScriptQuoteLocatorSelfTests {
    static func run() {
        assertExactMatchIsFound()
        assertTypographicPunctuationStillMatches()
        assertWhitespaceDifferencesStillMatch()
        assertWordSequenceFindsParaphrasedQuote()
        assertWordSequenceToleratesDroppedWord()
        assertUnrelatedQuoteReturnsNil()
        assertShortQuoteDoesNotMatchNoise()
        assertNormalisationPreservesOriginalOffsets()
        assertPhaseRoundTripsToTheSameNeighbourhood()
        assertPhaseRefusesWithoutMeasuredLayout()
        assertPhaseStaysWithinOneLoop()
    }

    /// Distinct content per section, so a match proves it found the *right*
    /// section rather than merely finding identical text somewhere.
    private static func makeScript(sections: Int = 40) -> String {
        (0..<sections)
            .map { "SECTION \($0): guidance topic \($0 * 7 + 3) covers objection number \($0) in detail." }
            .joined(separator: "\n\n")
    }

    // MARK: - Locating

    private static func assertExactMatchIsFound() {
        let script = makeScript()
        let quote = "SECTION 17: guidance topic 122 covers objection number 17 in detail."
        guard let match = ScriptQuoteLocator.locate(quote: quote, in: script) else {
            assert(false, "An exact quote must be found")
            return
        }
        assert(match.kind == .exact, "Expected an exact match, got \(match.kind)")
        assert(match.confidence == 1.0, "Exact match should be full confidence")
        let located = String(script[script.index(script.startIndex, offsetBy: match.characterIndex)...])
        assert(located.hasPrefix("SECTION 17"), "Match should point at section 17, got: \(located.prefix(40))")
    }

    private static func assertTypographicPunctuationStillMatches() {
        let script = "He said “don't worry” about pricing – it’s fine."
        // Curly quotes, curly apostrophe, en dash.
        let quote = "he said \"don't worry\" about pricing - it's fine"
        guard let match = ScriptQuoteLocator.locate(quote: quote, in: script) else {
            assert(false, "Typographic punctuation must still match")
            return
        }
        assert(match.kind == .normalized, "Expected a normalised match, got \(match.kind)")
        assert(match.characterIndex == 0, "Match should start at the beginning, got \(match.characterIndex)")
    }

    private static func assertWhitespaceDifferencesStillMatch() {
        let script = "alpha beta   gamma\n\ndelta epsilon"
        let quote = "alpha beta gamma delta epsilon"
        guard let match = ScriptQuoteLocator.locate(quote: quote, in: script) else {
            assert(false, "Whitespace differences must still match")
            return
        }
        assert(match.characterIndex == 0, "Should resolve back to offset 0, got \(match.characterIndex)")
    }

    private static func assertWordSequenceFindsParaphrasedQuote() {
        let script = makeScript()
        // The model dropped a word from the middle and dropped the trailing
        // period, so an exact and a normalised match both fail.
        let quote = "guidance topic 122 covers objection 17 in detail"
        guard let match = ScriptQuoteLocator.locate(quote: quote, in: script) else {
            assert(false, "A paraphrased quote must still be found")
            return
        }
        assert(match.kind == .wordSequence, "Expected a word-sequence match, got \(match.kind)")
        assert(match.confidence >= 0.5, "Confidence too low: \(match.confidence)")

        // It must land on section 17, not just any section.
        let located = String(script.prefix(match.characterIndex + match.matchedLength))
        assert(located.contains("SECTION 17"), "Should land on section 17, got: \(located.suffix(60))")
    }

    private static func assertWordSequenceToleratesDroppedWord() {
        let script = makeScript()
        // Heavier paraphrase: several words missing, order preserved.
        let quote = "guidance 122 objection 17 detail"
        guard let match = ScriptQuoteLocator.locate(quote: quote, in: script) else {
            assert(false, "Must tolerate several dropped words")
            return
        }
        let located = String(script.prefix(match.characterIndex + match.matchedLength))
        assert(located.contains("SECTION 17"), "Should still land on section 17, got: \(located.suffix(60))")
    }

    private static func assertUnrelatedQuoteReturnsNil() {
        let script = makeScript()
        assert(
            ScriptQuoteLocator.locate(quote: "the mitochondria powerhouse of the cell", in: script) == nil,
            "An unrelated quote must not match"
        )
        assert(
            ScriptQuoteLocator.locate(quote: "", in: script) == nil,
            "An empty quote must not match"
        )
        assert(
            ScriptQuoteLocator.locate(quote: "anything", in: "") == nil,
            "An empty script must not match"
        )
    }

    private static func assertShortQuoteDoesNotMatchNoise() {
        let script = makeScript()
        // Two words is far too weak — this is the case that would otherwise
        // jump the speaker to a random place.
        assert(
            ScriptQuoteLocator.locate(quote: "objection handling", in: script) == nil,
            "A two-word quote should not be treated as a match"
        )
    }

    private static func assertNormalisationPreservesOriginalOffsets() {
        let script = "  First   line.\n\nSecond  line with  spaces.  "
        let mapping = ScriptQuoteLocator.normalizedWithOffsets(script)
        assert(mapping.text == "first line. second line with spaces.", "Unexpected normalised text: \(mapping.text)")

        // The normalised "second" should map back to somewhere in the original.
        let index = mapping.text.distance(from: mapping.text.startIndex, to: mapping.text.range(of: "second")!.lowerBound)
        let original = mapping.originalIndex(forNormalized: index)
        assert(original > 0, "Second line should map past the first, got \(original)")
        assert(original <= script.count, "Mapped offset must be inside the original")
    }

    // MARK: - Inverse mapping

    private static func snapshot(traversed: CGFloat, contentHeight: CGFloat, viewport: CGFloat = 150) -> ScriptPositionSnapshot {
        ScriptPositionSnapshot(
            phase: traversed - 20,
            contentHeight: contentHeight,
            viewportHeight: viewport,
            startAnchorOffset: 20,
            isRunning: false
        )
    }

    private static func assertPhaseRoundTripsToTheSameNeighbourhood() {
        let script = makeScript(sections: 40)
        // 40 sections, ~80 chars each => ~3200 chars. At fontSize 20 the line
        // height is 24, so a plausible content height is a few thousand points.
        let contentHeight: CGFloat = 3200
        let snap = snapshot(traversed: 0, contentHeight: contentHeight)

        for targetFraction in stride(from: 0.1, through: 0.9, by: 0.1) {
            let index = Int(Double(script.count) * targetFraction)

            guard let phase = ScriptTextMapper.phaseForCharacterIndex(
                characterIndex: index,
                script: script,
                snapshot: snap,
                fontSize: 20
            ) else {
                assert(false, "Phase mapping returned nil for index \(index)")
                return
            }

            // The scroller's travelled distance is phase + anchor offset.
            let travelled = phase + snap.startAnchorOffset
            let recoveredFraction = Double(travelled / contentHeight)
            assert(
                abs(recoveredFraction - targetFraction) < 0.12,
                "Round trip drifted: wanted \(targetFraction), got \(recoveredFraction)"
            )
        }
    }

    private static func assertPhaseRefusesWithoutMeasuredLayout() {
        let script = makeScript()
        let unsized = snapshot(traversed: 0, contentHeight: 0)
        assert(
            ScriptTextMapper.phaseForCharacterIndex(
                characterIndex: 100, script: script, snapshot: unsized, fontSize: 20
            ) == nil,
            "Must refuse to produce a position without measured layout"
        )
    }

    private static func assertPhaseStaysWithinOneLoop() {
        let script = makeScript(sections: 200)
        let contentHeight: CGFloat = 20_000
        let snap = snapshot(traversed: 0, contentHeight: contentHeight)
        guard let last = ScriptTextMapper.phaseForCharacterIndex(
            characterIndex: script.count, script: script, snapshot: snap, fontSize: 20
        ) else {
            assert(false, "Expected a phase for the final character")
            return
        }
        // The final character must not push us past a full loop of content.
        let cycleLength = contentHeight + 24
        assert(
            last < cycleLength,
            "Phase \(last) exceeded one loop (\(cycleLength)); the scroller would wrap oddly"
        )
    }
}
