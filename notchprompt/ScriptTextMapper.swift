//
//  ScriptTextMapper.swift
//  notchprompt
//
//  Translates teleprompter scroll position into a location in the script text,
//  so an AI prompt can be told what the speaker is looking at *right now*
//  rather than sending the first N characters of the whole talk.
//
//  Mapping is necessarily approximate — the renderer wraps text itself, and
//  SwiftUI does not expose per-line metrics — so this is calibrated from the
//  *measured* content height rather than a guessed character width. That
//  absorbs differences in wrapping, font metrics, and DPI automatically.
//

import Foundation
import CoreGraphics

/// Where the speaker currently is in their script, in a form an LLM can use.
struct ScriptContext: Equatable {
    /// 0...1 through the script.
    let progress: Double
    /// Lines visible around the speaker's current position.
    let windowText: String
    /// True when `windowText` came from real measured layout rather than a
    /// fallback, so the caller can tell the model how much to trust it.
    let isPrecise: Bool

    var progressPercent: Int { Int((progress * 100).rounded()) }

    /// A coarse bucket of the script, used to keep cached answers from a
    /// different part of the talk from being reused.
    var positionBucket: Int {
        min(max(Int((progress * 4).rounded()), 0), 4)
    }
}

enum ScriptTextMapper {
    /// Characters to include on each side of the current position.
    static let defaultRadius = 1200

    /// Fallback context height as a multiple of the font size. SwiftUI's default
    /// line height for a text style is close to 1.2.
    static let lineHeightRatio: Double = 1.2

    /// Build context for the speaker's current position.
    ///
    /// - Parameters:
    ///   - snapshot: live scroll geometry from `ScriptPositionModel`.
    ///   - script: the full script text.
    ///   - fontSize: current teleprompter font size, which sets the line height.
    static func makeContext(
        snapshot: ScriptPositionSnapshot,
        script: String,
        fontSize: Double,
        radius: Int = defaultRadius
    ) -> ScriptContext {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ScriptContext(progress: 0, windowText: "", isPrecise: false)
        }

        // Without measured layout we cannot locate anything, so fall back to the
        // opening of the script rather than pretending to know the position.
        guard snapshot.hasMeasuredContent, fontSize > 0 else {
            return ScriptContext(
                progress: snapshot.progress,
                windowText: String(trimmed.prefix(radius)),
                isPrecise: false
            )
        }

        let lineHeight = fontSize * lineHeightRatio
        guard lineHeight > 0 else {
            return ScriptContext(
                progress: snapshot.progress,
                windowText: String(trimmed.prefix(radius)),
                isPrecise: false
            )
        }

        // Calibrate from measured height: total lines, then average characters
        // per line. This absorbs wrapping and font differences for free.
        let totalLines = max(1.0, Double(snapshot.contentHeight) / lineHeight)
        let charactersPerLine = max(1.0, Double(trimmed.count) / totalLines)

        let linesFromTop = Double(snapshot.traversedPoints) / lineHeight
        let rawIndex = Int((linesFromTop * charactersPerLine).rounded())
        let index = min(max(rawIndex, 0), trimmed.count)

        let window = window(in: trimmed, around: index, radius: radius)

        return ScriptContext(
            progress: snapshot.progress,
            windowText: window,
            isPrecise: true
        )
    }

    /// Substring of `radius` characters on each side of `index`, trimmed to
    /// character boundaries so partial words are less likely.
    static func window(in script: String, around index: Int, radius: Int) -> String {
        guard !script.isEmpty, radius > 0 else { return script }

        let lower = max(0, index - radius)
        let upper = min(script.count, index + radius)
        guard lower < upper else { return "" }

        let lowerIndex = script.index(script.startIndex, offsetBy: lower)
        let upperIndex = script.index(script.startIndex, offsetBy: upper)
        var slice = String(script[lowerIndex..<upperIndex])

        slice = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mark the cut points so the model can tell this is a fragment.
        if lower > 0 { slice = "…\n" + slice }
        if upper < script.count { slice += "\n…" }
        return slice
    }

    // MARK: - Inverse mapping

    /// The phase the scroller must be at for the given character index to sit
    /// comfortably inside the readable band of the viewport.
    ///
    /// This is the inverse of the mapping used by `makeContext`, calibrated the
    /// same way, so the two stay consistent by construction.
    ///
    /// - Parameter edgeFadeFraction: fraction of the viewport faded at top and
    ///   bottom by `ScrollingTextView`. The target is centred in the *clear*
    ///   band between the fades rather than at the top, where it would be hard
    ///   to read.
    static func phaseForCharacterIndex(
        characterIndex: Int,
        script: String,
        snapshot: ScriptPositionSnapshot,
        fontSize: Double,
        edgeFadeFraction: Double = 0.2
    ) -> CGFloat? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, fontSize > 0 else { return nil }

        let lineHeight = fontSize * lineHeightRatio
        guard lineHeight > 0 else { return nil }

        let clampedIndex = min(max(characterIndex, 0), trimmed.count)

        // Without measured content we cannot know the layout, so refuse to
        // produce a position rather than producing a wrong one.
        guard snapshot.hasMeasuredContent else { return nil }

        let totalLines = max(1.0, Double(snapshot.contentHeight) / lineHeight)
        let charactersPerLine = max(1.0, Double(trimmed.count) / totalLines)

        // Where the target sits in the content stack.
        let targetY = CGFloat(Double(clampedIndex) / charactersPerLine) * CGFloat(lineHeight)

        // Centre it in the readable band: the viewport minus the two fades.
        let fade = CGFloat(min(max(edgeFadeFraction, 0), 0.49))
        let clearBand = CGFloat(snapshot.viewportHeight) * (1 - fade * 2)
        let desiredY = snapshot.startAnchorOffset + max(clearBand, 0) / 2

        // effectiveOffsetY == -(phase mod cycleLength); solve for phase.
        let phase = targetY - desiredY
        return phase
    }

    /// Convert a `QuoteMatch` into a phase to seek to.
    static func phase(
        for match: QuoteMatch,
        script: String,
        snapshot: ScriptPositionSnapshot,
        fontSize: Double,
        edgeFadeFraction: Double = 0.2
    ) -> CGFloat? {
        phaseForCharacterIndex(
            characterIndex: match.characterIndex + match.matchedLength / 2,
            script: script,
            snapshot: snapshot,
            fontSize: fontSize,
            edgeFadeFraction: edgeFadeFraction
        )
    }
}
