//
//  OverlayGeometrySelfTests.swift
//  notchprompt
//
//  Checks for the screen-derived width rules. These exist because the previous
//  hardcoded range could push the overlay off the edges of a narrow display.
//

import Foundation

enum OverlayGeometrySelfTests {
    static func run() {
        assertRangeNeverEmptyOnAnyScreen()
        assertRangeScalesWithScreen()
        assertClampPreventsOverflow()
        assertClampEnforcesFloor()
        assertOversizedScreensStillCapped()
        assertPresetsAreOrderedAndReachable()
    }

    private static func assertRangeNeverEmptyOnAnyScreen() {
        // Absurd and degenerate widths must still yield a usable range.
        for width in [0.0, -100.0, 320.0, 640.0, 1024.0, 1512.0, 2560.0, 3840.0] {
            let range = OverlayGeometry.widthRange(forScreenWidth: width)
            assert(
                range.lowerBound <= range.upperBound,
                "Range inverted for screen width \(width): \(range)"
            )
            assert(
                range.lowerBound >= OverlayGeometry.minWidth - 0.001,
                "Range dipped below the floor for screen width \(width)"
            )
        }
    }

    private static func assertRangeScalesWithScreen() {
        let small = OverlayGeometry.widthRange(forScreenWidth: 1024)
        let large = OverlayGeometry.widthRange(forScreenWidth: 1512)
        assert(small.upperBound < large.upperBound, "A larger display should allow a wider overlay")

        // 90% of 1512 is 1361, under the 1400 ceiling.
        let mb = OverlayGeometry.widthRange(forScreenWidth: 1512)
        assert(mb.upperBound == 1361, "Expected 90% of 1512 = 1361, got \(mb.upperBound)")

        // A very wide display hits the absolute ceiling instead.
        let ultrawide = OverlayGeometry.widthRange(forScreenWidth: 3840)
        assert(ultrawide.upperBound == OverlayGeometry.maxWidth, "Expected the ceiling to cap at \(OverlayGeometry.maxWidth)")
    }

    private static func assertClampPreventsOverflow() {
        // The regression this replaces: 1200 on a 1024-wide display overflowed
        // by 88pt on each side.
        let clamped = OverlayGeometry.clamp(width: 1200, forScreenWidth: 1024)
        let range = OverlayGeometry.widthRange(forScreenWidth: 1024)
        assert(clamped == range.upperBound, "Expected clamping to \(range.upperBound), got \(clamped)")
        assert(clamped <= 1024, "Clamped width must not exceed the screen")
    }

    private static func assertClampEnforcesFloor() {
        let clamped = OverlayGeometry.clamp(width: 10, forScreenWidth: 1512)
        assert(clamped == OverlayGeometry.minWidth, "Expected the floor to be enforced, got \(clamped)")

        // Nonsense input should not propagate NaN into a window frame.
        // `isNaN`/`isFinite` rather than an ordering comparison: the compiler
        // constant-folds the literal and then wrongly reports the comparison as
        // always false.
        let nan = OverlayGeometry.clamp(width: .nan, forScreenWidth: 1512)
        assert(!nan.isNaN, "NaN width must be replaced, not passed through")
        assert(nan.isFinite, "Clamped width must always be finite")
    }

    private static func assertOversizedScreensStillCapped() {
        // Guard against a display-change notification leaving a stale huge value.
        let clamped = OverlayGeometry.clamp(width: 99999, forScreenWidth: 5120)
        assert(clamped == OverlayGeometry.maxWidth, "Expected the absolute ceiling, got \(clamped)")
    }

    private static func assertPresetsAreOrderedAndReachable() {
        let widths = OverlayGeometry.presets.map(\.width)
        assert(widths == widths.sorted(), "Presets should be ordered narrow to wide: \(widths)")
        assert(Set(OverlayGeometry.presets.map(\.id)).count == widths.count, "Preset ids must be unique")

        for preset in OverlayGeometry.presets {
            assert(
                preset.width >= OverlayGeometry.minWidth,
                "Preset \(preset.name) is below the floor"
            )
            assert(
                preset.width <= OverlayGeometry.maxWidth,
                "Preset \(preset.name) is above the ceiling"
            )
        }
    }
}
