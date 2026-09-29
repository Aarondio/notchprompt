//
//  SettingsRender.swift  (harness only — not part of the app target)
//
//  Renders ContentView to a PNG so the settings layout can be inspected
//  without a display, since screencapture is unavailable in CI.
//

import AppKit
import SwiftUI
import Combine

@MainActor
enum SettingsRender {
    static func render(to path: String) {
        // Give the library a little content so the layout is realistic.
        let library = ScriptLibrary.shared
        if library.scripts.isEmpty {
            library.save(
                name: "Discovery call opener",
                to: "Thanks for making the time today. I want to understand how your team currently handles reporting before I show you anything."
            )
            library.save(
                name: "Pricing — annual",
                to: "Our annual plan is fifty a seat per month, billed yearly. That includes unlimited viewers, the reporting suite, and priority support."
            )
        }

        // `history` is private(set) with no external mutator, so the recall
        // section renders empty here. Its layout is covered by
        // ListenHistorySelfTests; this harness focuses on the sections that
        // were previously never laid out at all.

        // ImageRenderer returns a blank image for this view tree, so rasterise
        // through a real AppKit-hosted view instead.
        let size = NSSize(width: 660, height: 2600)
        let hosting = NSHostingView(rootView: ContentView())
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))  // keep offscreen
        window.orderFront(nil)

        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hosting.displayIfNeeded()

        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            print("RENDER FAILED: no bitmap rep")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("RENDER FAILED: no png")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(png.count) bytes, \(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            print("WRITE FAILED: \(error.localizedDescription)")
        }
    }
}
