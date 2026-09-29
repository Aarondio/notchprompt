//
//  ScriptTextMapperSelfTests.swift
//  notchprompt
//
//  Checks for scroll-position to script-text mapping. The maths is inherently
//  approximate, so these pin the invariants that matter: monotonicity, bounds,
//  and honest degradation when layout has not been measured yet.
//

import Foundation
import CoreGraphics

enum ScriptTextMapperSelfTests {
    static func run() {
        assertStartOfScriptGivesOpeningLines()
        assertEndOfScriptGivesClosingLines()
        assertPositionIsMonotonic()
        assertContextIsAlwaysBounded()
        assertEmptyScriptYieldsNothing()
        assertUnmeasuredLayoutFallsBackHonestly()
        assertWindowIsSymmetricAroundIndex()
        assertWindowMarksBothCutPoints()
        assertProgressAndBucketStayInRange()
    }

    /// A long, line-numbered script so positions are easy to reason about.
    private static func script(lines: Int = 200, perLine: Int = 40) -> String {
        (0..<lines)
            .map { index in
                let label = String(format: "%03d", index)
                return String(repeating: label + " ", count: max(1, perLine / 4))
                    .prefix(perLine)
                    .description
            }
            .joined(separator: "\n")
    }

    private static func snapshot(
        traversed: CGFloat,
        contentHeight: CGFloat,
        anchor: CGFloat = 20,
        fontSize: Double = 20
    ) -> ScriptPositionSnapshot {
        // traversed == phase + startAnchorOffset, so phase = traversed - anchor
        ScriptPositionSnapshot(
            phase: traversed - anchor,
            contentHeight: contentHeight,
            viewportHeight: 150,
            startAnchorOffset: anchor,
            isRunning: true
        )
    }

    // MARK: - Positioning

    private static func assertStartOfScriptGivesOpeningLines() {
        let text = script()
        // fontSize 20 -> lineHeight 24. contentHeight 4800 -> 200 lines.
        let context = ScriptTextMapper.makeContext(
            snapshot: snapshot(traversed: 0, contentHeight: 4800),
            script: text,
            fontSize: 20
        )
        assert(context.isPrecise, "Measured layout should be treated as precise")
        assert(context.progress == 0, "At the top, progress should be 0")
        assert(context.windowText.contains("000"), "Top of the script should be in the window")
        assert(!context.windowText.contains("199"), "The far end must not appear at the top")
    }

    private static func assertEndOfScriptGivesClosingLines() {
        let text = script()
        let context = ScriptTextMapper.makeContext(
            snapshot: snapshot(traversed: 4800, contentHeight: 4800),
            script: text,
            fontSize: 20
        )
        assert(context.progress > 0.95, "At the end, progress should be near 1, got \(context.progress)")
        assert(context.windowText.contains("199"), "End of the script should be in the window")
    }

    private static func assertPositionIsMonotonic() {
        let text = script()
        var previous: ScriptContext?
        // 0%, 12.5%, 25%, ... of 4800 points
        for step in stride(from: 0.0, through: 4800.0, by: 600.0) {
            let context = ScriptTextMapper.makeContext(
                snapshot: snapshot(traversed: CGFloat(step), contentHeight: 4800),
                script: text,
                fontSize: 20
            )
            if let previous {
                assert(
                    context.progress >= previous.progress - 0.0001,
                    "Progress went backwards: \(previous.progress) then \(context.progress)"
                )
            }
            previous = context
        }
    }

    private static func assertContextIsAlwaysBounded() {
        let text = script(lines: 500, perLine: 60)
        // Deliberately absurd geometry must not produce an enormous window.
        let context = ScriptTextMapper.makeContext(
            snapshot: snapshot(traversed: 1_000_000, contentHeight: 1),
            script: text,
            fontSize: 20,
            radius: 200
        )
        assert(context.windowText.count <= 500, "Window must respect the radius, got \(context.windowText.count)")
    }

    private static func assertEmptyScriptYieldsNothing() {
        let context = ScriptTextMapper.makeContext(
            snapshot: snapshot(traversed: 100, contentHeight: 4800),
            script: "   \n  ",
            fontSize: 20
        )
        assert(context.windowText.isEmpty, "An empty script should produce no context")
        assert(!context.isPrecise, "An empty script cannot be precise")
    }

    private static func assertUnmeasuredLayoutFallsBackHonestly() {
        let text = script()
        let context = ScriptTextMapper.makeContext(
            snapshot: snapshot(traversed: 2400, contentHeight: 0),
            script: text,
            fontSize: 20,
            radius: 150
        )
        // Not precise, and it must not claim to be looking at the middle.
        assert(!context.isPrecise, "Without measured layout we must not claim precision")
        assert(context.windowText.hasPrefix("000"), "Fallback should be the opening of the script")
    }

    // MARK: - Window

    private static func assertWindowIsSymmetricAroundIndex() {
        let text = "0123456789" + String(repeating: "x", count: 100) + "ABCDEFGHIJ"
        let middle = text.count / 2
        let window = ScriptTextMapper.window(in: text, around: middle, radius: 20)

        // Should reach the same distance backwards and forwards.
        let suffixStart = window.lastIndex(of: "A") ?? window.startIndex
        let prefixDistance = window.distance(from: window.startIndex, to: suffixStart)
        assert(prefixDistance <= 30, "Window should be roughly symmetric, prefix distance \(prefixDistance)")
    }

    private static func assertWindowMarksBothCutPoints() {
        let text = String(repeating: "a", count: 500)
        let middle = ScriptTextMapper.window(in: text, around: 250, radius: 50)
        assert(middle.hasPrefix("…"), "A window cut from the middle should be marked at the start")
        assert(middle.hasSuffix("…"), "A window cut from the middle should be marked at the end")

        let whole = ScriptTextMapper.window(in: text, around: 250, radius: 10_000)
        assert(!whole.hasPrefix("…"), "A window covering everything should not be marked at the start")
        assert(!whole.hasSuffix("…"), "A window covering everything should not be marked at the end")
    }

    private static func assertProgressAndBucketStayInRange() {
        for step in stride(from: -500.0, through: 9000.0, by: 250.0) {
            let context = ScriptTextMapper.makeContext(
                snapshot: snapshot(traversed: CGFloat(step), contentHeight: 4800),
                script: script(),
                fontSize: 20
            )
            assert(
                context.progress >= 0 && context.progress <= 1,
                "progress escaped 0...1: \(context.progress)"
            )
            assert(
                context.positionBucket >= 0 && context.positionBucket <= 4,
                "positionBucket escaped 0...4: \(context.positionBucket)"
            )
            assert(
                context.progressPercent >= 0 && context.progressPercent <= 100,
                "progressPercent escaped 0...100: \(context.progressPercent)"
            )
        }
    }
}
