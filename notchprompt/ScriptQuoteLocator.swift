//
//  ScriptQuoteLocator.swift
//  notchprompt
//
//  Finds where a quoted passage sits inside the script.
//
//  Needed because the model will not return a quote that matches the script
//  byte for byte: it may normalise whitespace, use typographic quotes or
//  dashes, and it truncates. So matching degrades in stages, and a miss is a
//  completely normal outcome rather than an error.
//

import Foundation

struct QuoteMatch: Equatable {
    enum Kind: Equatable {
        /// Found verbatim.
        case exact
        /// Found after case/whitespace/punctuation normalisation.
        case normalized
        /// Found by matching a run of words.
        case wordSequence
    }

    let characterIndex: Int
    let matchedLength: Int
    let kind: Kind
    /// 0...1, how much of the quote was actually located.
    let confidence: Double
}

enum ScriptQuoteLocator {
    // MARK: - Normalisation

    /// Fold typographic characters to their ASCII equivalents and collapse runs
    /// of whitespace, so "don't" in the script matches "don’t" from the model.
    static func normalizeForMatching(_ text: String) -> String {
        var s = text
        let replacements: [(String, String)] = [
            ("\u{2018}", "'"), ("\u{2019}", "'"),
            ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2013}", "-"), ("\u{2014}", "-"),
            ("\u{00A0}", " "), ("\u{200B}", ""),
            ("\u{2026}", "...")
        ]
        for (from, to) in replacements {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Words with their character offset in the original string, so a match can
    /// be reported as a position rather than just a boolean.
    struct Token {
        let word: String
        let index: Int
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = 0

        func flush(end: Int) {
            if !current.isEmpty {
                tokens.append(Token(word: current, index: start))
                current = ""
            }
            _ = end
        }

        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if current.isEmpty { start = offset }
                current.append(character)
            } else {
                flush(end: offset)
            }
            offset += 1
            index = text.index(after: index)
        }
        flush(end: offset)
        return tokens
    }

    // MARK: - Location

    /// Locate `quote` inside `script`, degrading through increasingly loose
    /// strategies. Returns nil when nothing plausible is found — the caller
    /// should then simply show the answer without jumping.
    static func locate(quote: String, in script: String) -> QuoteMatch? {
        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuote.isEmpty, !script.isEmpty else { return nil }

        // 1. Verbatim.
        if let range = script.range(of: trimmedQuote) {
            let index = script.distance(from: script.startIndex, to: range.lowerBound)
            return QuoteMatch(
                characterIndex: index,
                matchedLength: script.distance(from: range.lowerBound, to: range.upperBound),
                kind: .exact,
                confidence: 1.0
            )
        }

        // 2. Normalised substring. Build a normalised copy of the script that
        // preserves a character-offset lookup back to the original.
        let mapping = normalizedWithOffsets(script)
        let normalizedQuote = normalizeForMatching(trimmedQuote)
        if let range = mapping.text.range(of: normalizedQuote) {
            let normalizedIndex = mapping.text.distance(from: mapping.text.startIndex, to: range.lowerBound)
            let originalIndex = mapping.originalIndex(forNormalized: normalizedIndex)
            let matchedLength = mapping.text.distance(from: range.lowerBound, to: range.upperBound)
            return QuoteMatch(
                characterIndex: originalIndex,
                matchedLength: max(matchedLength, 1),
                kind: .normalized,
                confidence: 0.9
            )
        }

        // 3. Word sequence: require at least three words and a good run.
        return locateByWordSequence(quote: trimmedQuote, in: script)
    }

    // MARK: - Normalised copy with offset mapping

    struct NormalizedText {
        let text: String
        /// For each character index in `text`, the corresponding offset in the
        /// original. Slightly over-allocated so lookups never trap.
        let originalOffsets: [Int]

        func originalIndex(forNormalized index: Int) -> Int {
            guard !originalOffsets.isEmpty else { return 0 }
            return originalOffsets[min(max(index, 0), originalOffsets.count - 1)]
        }
    }

    /// Lowercase, collapse whitespace and normalise punctuation while recording
    /// where each resulting character came from.
    static func normalizedWithOffsets(_ input: String) -> NormalizedText {
        var text = ""
        var offsets: [Int] = []
        var pendingSpace = false

        var originalIndex = input.startIndex
        var offset = 0

        while originalIndex < input.endIndex {
            let character = input[originalIndex]

            if character.isWhitespace {
                pendingSpace = !text.isEmpty
                originalIndex = input.index(after: originalIndex)
                offset += 1
                continue
            }

            var folded = String(character).lowercased()
            switch character {
            case "\u{2018}", "\u{2019}": folded = "'"
            case "\u{201C}", "\u{201D}": folded = "\""
            case "\u{2013}", "\u{2014}": folded = "-"
            case "\u{00A0}": folded = " "
            case "\u{200B}": folded = ""
            case "\u{2026}": folded = "..."
            default: break
            }

            if pendingSpace {
                text.append(" ")
                offsets.append(offset)
                pendingSpace = false
            }
            for scalar in folded.unicodeScalars {
                text.unicodeScalars.append(scalar)
                offsets.append(offset)
            }

            originalIndex = input.index(after: originalIndex)
            offset += 1
        }

        // Sentinel so `originalIndex(forNormalized:)` is always in range.
        offsets.append(offset)
        return NormalizedText(text: text, originalOffsets: offsets)
    }

    // MARK: - Word sequence

    private static func locateByWordSequence(quote: String, in script: String) -> QuoteMatch? {
        let quoteTokens = tokenize(normalizeForMatching(quote))
        let scriptTokens = tokenize(script)
        guard quoteTokens.count >= 3, scriptTokens.count >= quoteTokens.count else { return nil }

        var best: QuoteMatch?

        for start in 0...(scriptTokens.count - quoteTokens.count) {
            // Gap-tolerant in-order matching. A naive consecutive-run comparison
            // fails on the common case where the model drops or rewords a word
            // in the middle of a quote.
            var quoteCursor = 0
            var scriptCursor = start
            var matches = 0
            var lastMatched = start
            let maxGap = 24

            while quoteCursor < quoteTokens.count, scriptCursor < scriptTokens.count {
                if scriptCursor - start > maxGap { break }
                if quoteTokens[quoteCursor].word == scriptTokens[scriptCursor].word {
                    matches += 1
                    lastMatched = scriptCursor
                    quoteCursor += 1
                    scriptCursor += 1
                } else {
                    scriptCursor += 1
                }
            }

            guard matches >= 3 else { continue }

            let confidence = Double(matches) / Double(quoteTokens.count)
            // Prefer longer contiguous coverage when confidences tie.
            let coverage = lastMatched - start + 1
            let isBetter = match(best, confidence: confidence, coverage: coverage)
            if isBetter {
                let firstIndex = scriptTokens[start].index
                let endIndex = lastMatched + 1 < scriptTokens.count
                    ? scriptTokens[lastMatched + 1].index
                    : script.count
                best = QuoteMatch(
                    characterIndex: firstIndex,
                    matchedLength: max(1, endIndex - firstIndex),
                    kind: .wordSequence,
                    confidence: confidence
                )
            }
        }

        // Below this the "match" is mostly noise, and a wrong jump is far worse
        // than no jump at all.
        return (best?.confidence ?? 0) >= 0.5 ? best : nil
    }

    private static func match(_ existing: QuoteMatch?, confidence: Double, coverage: Int) -> Bool {
        guard let existing else { return true }
        if confidence != existing.confidence { return confidence > existing.confidence }
        return coverage > existing.matchedLength
    }
}
