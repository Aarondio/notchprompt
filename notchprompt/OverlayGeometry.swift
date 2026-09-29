//
//  OverlayGeometry.swift
//  notchprompt
//
//  Width rules for the notch overlay.
//
//  The overlay width is the user's *desired* width; the range it may occupy is
//  derived from whichever display the overlay is currently targeting. A fixed
//  400–1200 range was wrong in both directions: it could overflow the edges of
//  a narrow display, and it needlessly restricted large ones.
//

import AppKit
import CoreGraphics

enum OverlayGeometry {
    // MARK: - Width rules

    static let minWidth: Double = 340
    static let maxWidth: Double = 1400
    /// Fraction of the target display the overlay may occupy.
    static let screenFraction: Double = 0.9
    static let widthStep: Double = 40

    /// Width the transport control row needs before it starts to overflow.
    ///
    /// Derived from the layout in `OverlayView`: three buttons in the left
    /// group, six in the right, plus capsule padding, inter-group spacing and
    /// the row's own outer padding. **Keep in sync when adding or removing a
    /// control button** — `OverlayGeometrySelfTests` fails if the row outgrows
    /// `minWidth`, which is the tripwire for forgetting to raise the floor.
    static let controlRowMinimumWidth: Double = controlRowWidth()

    private static func controlRowWidth() -> Double {
        // Every local is explicitly typed: the arithmetic below is written as a
        // single chain otherwise, and the type checker gives up on it.
        let buttonWidth: Double = 22
        let buttonSpacing: Double = 6
        let capsulePadding: Double = 16
        let leftButtons: Double = 3    // play/pause, jump back, mic
        let rightButtons: Double = 6   // paste, clear, speed -, speed +, gear, quit
        let interGroupGaps: Double = 24
        let outerPadding: Double = 20

        let left: Double = leftButtons * buttonWidth + (leftButtons - 1) * buttonSpacing + capsulePadding
        let right: Double = rightButtons * buttonWidth + (rightButtons - 1) * buttonSpacing + capsulePadding
        let total: Double = left + right + interGroupGaps + outerPadding
        return total
    }

    struct Preset: Identifiable, Equatable {
        let id: String
        let name: String
        let width: Double
    }

    static let presets: [Preset] = [
        Preset(id: "compact", name: "Compact", width: 420),
        Preset(id: "default", name: "Default", width: 600),
        Preset(id: "wide", name: "Wide", width: 900),
        Preset(id: "ultrawide", name: "Ultra", width: 1200)
    ]

    /// The permitted width range on a display of `screenWidth` points.
    ///
    /// Always contains at least `minWidth`, so an absurdly narrow display still
    /// yields a usable (if tight) range rather than an invalid one.
    static func widthRange(forScreenWidth screenWidth: Double) -> ClosedRange<Double> {
        let floor = minWidth
        guard screenWidth.isFinite, screenWidth > 0 else { return floor...maxWidth }
        let ceiling = min(maxWidth, max(floor, (screenWidth * screenFraction).rounded()))
        return floor...max(floor, ceiling)
    }

    static func clamp(width: Double, forScreenWidth screenWidth: Double) -> Double {
        let range = widthRange(forScreenWidth: screenWidth)
        guard width.isFinite else { return range.lowerBound }
        return min(max(width, range.lowerBound), range.upperBound)
    }

    // MARK: - Target display

    /// Resolve the display the overlay should sit on, mirroring the preference
    /// rules in `ScreenSelection`. Shared so the window controller and the
    /// width-range maths always agree on which display matters.
    static func targetScreen(selectedScreenID: CGDirectDisplayID) -> NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.compactMap { screen -> ScreenDescriptor? in
            guard let id = displayID(for: screen) else { return nil }
            return ScreenDescriptor(
                id: id,
                localizedName: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMenuBarScreen: id == CGMainDisplayID()
            )
        }

        guard let targetID = ScreenSelection.chooseScreenID(
            selectedScreenID: selectedScreenID,
            screens: descriptors
        ) else {
            return nil
        }

        return screens.first(where: { displayID(for: $0) == targetID })
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(n.uint32Value)
    }

    /// Width of the target display, used to derive the allowed range.
    static func targetScreenWidth(selectedScreenID: CGDirectDisplayID) -> Double {
        let screen = targetScreen(selectedScreenID: selectedScreenID)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return 1440 }
        return Double(screen.frame.width)
    }
}
