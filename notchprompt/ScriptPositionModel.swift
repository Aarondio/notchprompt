//
//  ScriptPositionModel.swift
//  notchprompt
//
//  Surfaces the teleprompter's scroll position to the rest of the app so that
//  non-view code (AI context, jump-to-line) can read where the speaker is.
//
//  PERFORMANCE NOTE
//  The scroll phase advances on every animation frame while running (~60Hz).
//  It is deliberately NOT an @Published property here: publishing it would
//  invalidate every observing view on every frame and tank scrolling. Instead
//  `ScrollingTextView` mirrors an immutable snapshot in here at frame rate
//  (a plain struct assignment), and only low-frequency derived values —
//  whole-percent progress — are published for UI use.
//
//  This is also the read/write seam that lets the AI layer pull the current
//  position synchronously when it builds a prompt.
//

import Foundation
import CoreGraphics
import Combine

/// Immutable capture of the teleprompter's scroll geometry at a point in time.
struct ScriptPositionSnapshot: Equatable, Sendable {
    let phase: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    /// Offset used to park the first line of the script in the viewport.
    let startAnchorOffset: CGFloat
    let isRunning: Bool

    /// Distance scrolled since the script's first line was anchored.
    var traversedPoints: CGFloat {
        phase + startAnchorOffset
    }

    /// How far through the script the viewport is, clamped to 0...1.
    var progress: Double {
        guard contentHeight > 0 else { return 0 }
        let raw = Double(traversedPoints / contentHeight)
        return min(max(raw, 0), 1)
    }

    /// True once the script has real content laid out and its height measured.
    var hasMeasuredContent: Bool {
        contentHeight > 1
    }

    static let initial = ScriptPositionSnapshot(
        phase: 0,
        contentHeight: 1,
        viewportHeight: 0,
        startAnchorOffset: 0,
        isRunning: false
    )
}

/// A range of the script to highlight after jumping to it.
struct ScriptHighlight: Equatable {
    let range: Range<Int>
    /// Bumped per request so repeated jumps to the same range still trigger.
    let token: UUID

    static func == (lhs: ScriptHighlight, rhs: ScriptHighlight) -> Bool {
        lhs.token == rhs.token
    }
}

@MainActor
final class ScriptPositionModel: ObservableObject {
    static let shared = ScriptPositionModel()

    // MARK: - Highlight

    /// Currently highlighted passage, set when jumping to a quote.
    @Published var highlight: ScriptHighlight?

    func clearHighlight() {
        highlight = nil
    }

    // MARK: - Coarse values, published for UI only

    /// Whole-percent progress through the script. Throttled; see `publishInterval`.
    @Published private(set) var progressPercent: Int = 0
    @Published private(set) var progressFraction: Double = 0

    // MARK: - Seek command channel

    /// Bumped whenever a seek is requested. Mirrors the existing
    /// `resetToken` / `jumpBackToken` convention used by the scroller.
    @Published private(set) var seekToken: UUID = UUID()
    /// Pending seek target, consumed by the scroller. Not published — the
    /// token change is the signal, this carries the payload.
    private(set) var pendingSeekPhase: CGFloat?

    // MARK: - Pause / resume

    /// Last phase captured when scrolling paused, restored when the overlay
    /// reappears. Replaces the old `PrompterModel.savedScrollPhaseForResume`.
    private(set) var savedPhaseForResume: CGFloat?

    // MARK: - Fine-grained state (pull-only, safe to read any time on main)

    /// Latest frame-accurate state. Intentionally not published.
    private(set) var snapshot: ScriptPositionSnapshot = .initial

    private var lastPublishDate = Date.distantPast
    private let publishInterval: TimeInterval = 0.5

    // MARK: - Called by ScrollingTextView (frame rate)

    /// Mirror new scroll state. Cheap: a struct store plus a throttled
    /// comparison, with no view invalidation on the common path.
    func update(_ new: ScriptPositionSnapshot) {
        snapshot = new

        let now = Date()
        guard now.timeIntervalSince(lastPublishDate) >= publishInterval else { return }

        let fraction = new.progress
        let percent = Int((fraction * 100).rounded())
        guard percent != progressPercent || abs(fraction - progressFraction) > 0.005 else { return }

        progressPercent = percent
        progressFraction = fraction
        lastPublishDate = now
    }

    // MARK: - Scroller lifecycle

    /// Called when the script is reset or replaced.
    func reset() {
        snapshot = .initial
        progressPercent = 0
        progressFraction = 0
        savedPhaseForResume = nil
        pendingSeekPhase = nil
        // Drop any highlight too. `ScrollingTextView` calls this whenever the
        // script text is replaced, and a leftover range would otherwise be
        // interpreted against the new text — highlighting an arbitrary span of
        // a script the user never asked to jump to.
        clearHighlight()
    }

    /// Called when scrolling pauses so the position can be restored later.
    func savePhaseForResume() {
        savedPhaseForResume = snapshot.phase
    }

    // MARK: - Seek API

    /// Request an absolute seek, in the same phase units the scroller uses.
    func requestSeek(toPhase target: CGFloat) {
        pendingSeekPhase = target
        seekToken = UUID()
    }

    /// Request a seek by fraction of the script, 0...1.
    func requestSeek(toProgress fraction: Double) {
        let current = snapshot
        let clamped = min(max(fraction, 0), 1)
        let target = -current.startAnchorOffset + CGFloat(clamped) * current.contentHeight
        requestSeek(toPhase: target)
    }

    /// Called by the scroller once it has applied a pending seek.
    func consumePendingSeekPhase() -> CGFloat? {
        defer { pendingSeekPhase = nil }
        return pendingSeekPhase
    }

    // MARK: - Read helpers (for future AI context work)

    /// Points remaining until the end of the script, for stop-at-end mode.
    func pointsRemaining(toEndAt endPhase: CGFloat) -> CGFloat {
        max(0, endPhase - snapshot.phase)
    }
}
