//
//  OverlayWindowController.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import CoreGraphics
import SwiftUI

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Make panel key BEFORE dispatching mouse events so SwiftUI gesture
    /// recognizers process them in a key-window context.  `sendEvent` fires
    /// before any view dispatch, unlike `mouseDown` which fires after.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isKeyWindow { makeKey() }
        default:
            break
        }
        super.sendEvent(event)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        Task { @MainActor in
            PrompterModel.shared.pasteScript(text)
        }
    }

    @objc func clearScript(_ sender: Any?) {
        Task { @MainActor in
            PrompterModel.shared.script = ""
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let view = contentView else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear", action: #selector(clearScript(_:)), keyEquivalent: ""))
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayWindowController {
    private let model: PrompterModel
    private let panel: NSPanel
    // Keep this at 0 to hug the notch/menu bar boundary like other notch-adjacent apps.
    // We still position using `visibleFrame` so we never enter the reserved top strip.
    private let padding: CGFloat = 0
    private let inMenuBarStrip: Bool = true
    private var lastFrame: NSRect?
    private var privacyEnforceTimer: Timer?
    private var sharingTypeObservation: NSKeyValueObservation?

    init(model: PrompterModel) {
        self.model = model

        let hosting = ClickThroughHostingView(rootView: OverlayView(model: model))

        let initialFrame = NSRect(x: 0, y: 0, width: model.overlayWidth, height: model.effectiveOverlayHeight)
        let panel = OverlayPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        // Use .screenSaver level to ensure it sits above the menu bar and covers the notch area.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // panel.isFloatingPanel = true // This overrides level to .floating (3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 1.0
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = false
        // Enforced hidden from screen capture / screen sharing / screen recording:
        // .none is best-effort but is respected by CGWindowList, ScreenCaptureKit, Zoom/Meet.
        // We force .none regardless of the legacy privacy toggle so the notch is never capturable.
        panel.sharingType = .none

        panel.contentView = hosting
        self.panel = panel

        reposition()
        // KVO hard-enforce: if any code (or OS) flips sharingType away from .none, snap it back.
        sharingTypeObservation = panel.observe(\.sharingType, options: [.new]) { p, _ in
            if p.sharingType != .none {
                Task { @MainActor in p.sharingType = .none }
            }
        }
        // Periodic re-assertion: some capture stacks poll window properties; keep .none pinned.
        privacyEnforceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak panel] _ in
            Task { @MainActor in
                if panel?.sharingType != NSWindow.SharingType.none { panel?.sharingType = NSWindow.SharingType.none }
            }
        }
        RunLoop.main.add(privacyEnforceTimer!, forMode: .common)

#if DEBUG
        debugDump(reason: "init-after-reposition", intendedScreen: targetScreen(), calc: nil)
#endif
    }

    func setVisible(_ isVisible: Bool) {
#if DEBUG
        debugDump(reason: "setVisible-before isVisible=\(isVisible)", intendedScreen: targetScreen(), calc: nil)
#endif
        if isVisible {
            // Ensure the panel can reappear even when the app is backgrounded.
            reposition()
            panel.sharingType = .none
            panel.level = .screenSaver
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            panel.sharingType = .none
        } else {
            panel.orderOut(nil)
        }
#if DEBUG
        debugDump(reason: "setVisible-after isVisible=\(isVisible)", intendedScreen: targetScreen(), calc: nil)
#endif
    }

    func reposition() {
        guard let screen = targetScreen() ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Clamp to the target display so a wide setting can never push the
        // panel off both edges of a narrow screen.
        let width = OverlayGeometry.clamp(
            width: model.overlayWidth,
            forScreenWidth: screen.frame.width
        )
        let desiredHeight = CGFloat(model.effectiveOverlayHeight)

        let x = (screen.frame.midX - (width / 2)).rounded()

        // Always pin to the very top of the physical screen so we cover the notch/menu bar
        // even when macOS auto-hides the menu bar (reservedTop may report as 0).
        let height = desiredHeight
        let topRefY = screen.frame.maxY
        let y = (topRefY - height - padding).rounded()
        let targetFrame = NSRect(x: x, y: y, width: width.rounded(), height: height.rounded())

#if DEBUG
        debugDump(
            reason: "reposition-pre",
            intendedScreen: screen,
            calc: Calc(width: width, height: height, padding: padding, x: x, y: y, topSafeY: topRefY)
        )
#endif

        let shouldAnimate: Bool
        if let lastFrame {
            let movedEnough = abs(lastFrame.origin.x - targetFrame.origin.x) > 0.5 ||
                abs(lastFrame.origin.y - targetFrame.origin.y) > 0.5
            let resizedEnough = abs(lastFrame.size.width - targetFrame.size.width) > 0.5 ||
                abs(lastFrame.size.height - targetFrame.size.height) > 0.5
            shouldAnimate = movedEnough || resizedEnough
        } else {
            shouldAnimate = false
        }

        panel.setFrame(targetFrame, display: true, animate: shouldAnimate)
        lastFrame = targetFrame
        
        // Re-enforce hidden-from-capture after every move (some capturers poll window props)
        panel.sharingType = .none
        // Ensure level is re-applied in case something reset it
        panel.level = .screenSaver
        panel.alphaValue = 1.0

#if DEBUG
        debugDump(
            reason: "reposition-post",
            intendedScreen: screen,
            calc: Calc(width: width, height: height, padding: padding, x: x, y: y, topSafeY: topRefY)
        )
#endif
    }

    func setPrivacyMode(_ enabled: Bool) {
        // Privacy is now always-on: notch is never capturable by screen recorders/sharing.
        // Keep API compat but ignore `enabled` — we always force .none.
        panel.sharingType = .none
#if DEBUG
        debugDump(
            reason: "setPrivacyMode enforced .none (requested enabled=\(enabled)) sharingType=\(panel.sharingType.rawValue)",
            intendedScreen: targetScreen(),
            calc: nil
        )
#endif
    }

    private func targetScreen() -> NSScreen? {
        OverlayGeometry.targetScreen(selectedScreenID: model.selectedScreenID)
    }
}

#if DEBUG
private extension OverlayWindowController {
    struct Calc {
        let width: CGFloat
        let height: CGFloat
        let padding: CGFloat
        let x: CGFloat
        let y: CGFloat
        let topSafeY: CGFloat
    }

    func debugDump(reason: String, intendedScreen: NSScreen?, calc: Calc?) {
        let level = panel.level

        let intendedName = intendedScreen?.localizedName ?? "nil"
        let intendedFrame = intendedScreen?.frame.debugDescription ?? "nil"
        let intendedVisible = intendedScreen?.visibleFrame.debugDescription ?? "nil"
        let reservedTop: CGFloat = {
            guard let s = intendedScreen else { return .nan }
            return max(0, s.frame.maxY - s.visibleFrame.maxY)
        }()

        let panelFrame = panel.frame
        let panelMaxY = panelFrame.maxY

        let actualScreen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: panelFrame.midX, y: panelFrame.midY))
        }
        let actualName = actualScreen?.localizedName ?? "nil"
        let actualFrame = actualScreen?.frame.debugDescription ?? "nil"
        let actualVisible = actualScreen?.visibleFrame.debugDescription ?? "nil"
        print("[Notchprompt][Overlay] reason=\(reason)")
        print("level=\(String(describing: level))(raw=\(level.rawValue)) ignoresMouseEvents=\(panel.ignoresMouseEvents)")
        print("panel.frame=\(panelFrame.debugDescription) panel.maxY=\(panelMaxY)")
        print("screen(name=\(intendedName), frame=\(intendedFrame), visible=\(intendedVisible), reservedTop=\(reservedTop))")
        if let calc {
            print("calc(width=\(calc.width), height=\(calc.height), padding=\(calc.padding), x=\(calc.x), y=\(calc.y), topSafeY=\(calc.topSafeY))")
        } else {
            print("calc(nil)")
        }
        print("actualScreen(name=\(actualName), frame=\(actualFrame), visible=\(actualVisible))")
        // Overlapping the reserved top region is expected when we intentionally cover the notch/menu bar area.
    }
}
#endif
