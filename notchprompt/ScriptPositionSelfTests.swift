//
//  ScriptPositionSelfTests.swift
//  notchprompt
//
//  Checks for the pure logic introduced by ScriptPositionModel:
//  progress math, seek targeting, and the throttle invariant.
//
//

import Foundation
import CoreGraphics

@MainActor
enum ScriptPositionSelfTests {
    static func run() {
        assertProgressStartsAtZero()
        assertProgressTracksScroll()
        assertProgressClampedToUnitRange()
        assertProgressZeroWithoutContent()
        assertSeekByProgressMapsIntoPhaseRange()
        assertSeekClampsOutOfRangeProgress()
        assertResetClearsState()
        assertSnapshotGeometryRoundTrip()
    }

    // MARK: - Progress math

    private static func assertProgressStartsAtZero() {
        let snapshot = ScriptPositionSnapshot(
            phase: -20,
            contentHeight: 1000,
            viewportHeight: 150,
            startAnchorOffset: 20,
            isRunning: false
        )
        assert(abs(snapshot.progress) < 0.0001, "Progress should be 0 at the script's first line")
    }

    private static func assertProgressTracksScroll() {
        let snapshot = ScriptPositionSnapshot(
            phase: 480, // 500 points traversed, minus the 20pt anchor offset
            contentHeight: 1000,
            viewportHeight: 150,
            startAnchorOffset: 20,
            isRunning: true
        )
        assert(abs(snapshot.progress - 0.5) < 0.0001, "Expected 0.5 progress at the halfway point")
        assert(abs(snapshot.traversedPoints - 500) < 0.0001, "Expected 500 traversed points")
    }

    private static func assertProgressClampedToUnitRange() {
        let overshoot = ScriptPositionSnapshot(
            phase: 5_000,
            contentHeight: 1000,
            viewportHeight: 150,
            startAnchorOffset: 20,
            isRunning: true
        )
        assert(overshoot.progress == 1.0, "Progress must clamp to 1.0 past the end")

        let undershoot = ScriptPositionSnapshot(
            phase: -9_000,
            contentHeight: 1000,
            viewportHeight: 150,
            startAnchorOffset: 20,
            isRunning: false
        )
        assert(undershoot.progress == 0.0, "Progress must clamp to 0.0 before the start")
    }

    private static func assertProgressZeroWithoutContent() {
        let snapshot = ScriptPositionSnapshot(
            phase: 400,
            contentHeight: 0,
            viewportHeight: 150,
            startAnchorOffset: 20,
            isRunning: true
        )
        assert(snapshot.progress == 0.0, "Progress must be 0 when there is no content to scroll")
    }

    // MARK: - Seek targeting

    private static func assertSeekByProgressMapsIntoPhaseRange() {
        let model = makeModel(
            contentHeight: 1000,
            viewportHeight: 150,
            startAnchorOffset: 20,
            phase: -20
        )

        model.requestSeek(toProgress: 0.5)
        let target = model.consumePendingSeekPhase()

        assert(target != nil, "A seek request should carry a phase target")
        // Halfway: -20 (anchor) + 0.5 * 1000
        assert(abs((target ?? 0) - 480) < 0.001, "Seek to 50% should target phase 480, got \(target ?? -1)")
        assert(model.consumePendingSeekPhase() == nil, "Seek target should be consumed exactly once")
    }

    private static func assertSeekClampsOutOfRangeProgress() {
        let model = makeModel(
            contentHeight: 1000,
            viewportHeight: 150,
            startAnchorOffset: 20,
            phase: -20
        )

        model.requestSeek(toProgress: 5.0)
        let high = model.consumePendingSeekPhase() ?? 0
        assert(abs(high - 980) < 0.001, "Progress above 1.0 should clamp to the end")

        model.requestSeek(toProgress: -3.0)
        let low = model.consumePendingSeekPhase() ?? 0
        assert(abs(low + 20) < 0.001, "Progress below 0.0 should clamp to the start")
    }

    // MARK: - Lifecycle

    private static func assertResetClearsState() {
        let model = makeModel(
            contentHeight: 1000,
            viewportHeight: 150,
            startAnchorOffset: 20,
            phase: 400
        )
        model.savePhaseForResume()
        model.requestSeek(toProgress: 0.8)

        model.reset()

        assert(model.savedPhaseForResume == nil, "Reset must clear the resume phase")
        assert(model.pendingSeekPhase == nil, "Reset must clear any pending seek")
        assert(model.progressPercent == 0, "Reset must clear published progress")
        assert(model.progressFraction == 0, "Reset must clear published progress fraction")
        assert(model.snapshot == .initial, "Reset must restore the initial snapshot")
    }

    private static func assertSnapshotGeometryRoundTrip() {
        let model = makeModel(
            contentHeight: 2400,
            viewportHeight: 300,
            startAnchorOffset: 44,
            phase: 1200
        )
        let snapshot = model.snapshot
        assert(snapshot.contentHeight == 2400, "contentHeight should round-trip")
        assert(snapshot.viewportHeight == 300, "viewportHeight should round-trip")
        assert(snapshot.startAnchorOffset == 44, "startAnchorOffset should round-trip")
        assert(snapshot.phase == 1200, "phase should round-trip")
    }

    // MARK: - Helpers

    /// Builds a model pre-loaded with geometry. A fresh model has never
    /// published, so the first `update` always passes the throttle — these
    /// assertions therefore see deterministic values.
    private static func makeModel(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        startAnchorOffset: CGFloat,
        phase: CGFloat
    ) -> ScriptPositionModel {
        let model = ScriptPositionModel()
        model.update(
            ScriptPositionSnapshot(
                phase: phase,
                contentHeight: contentHeight,
                viewportHeight: viewportHeight,
                startAnchorOffset: startAnchorOffset,
                isRunning: false
            )
        )
        return model
    }
}
