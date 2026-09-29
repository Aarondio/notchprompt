//
//  AppDelegate.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option]

    private let model = PrompterModel.shared

    private var statusItem: NSStatusItem?
    private var overlayController: OverlayWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var scriptEditorWindowController: ScriptEditorWindowController?
    private var cancellables: Set<AnyCancellable> = []

    private var startPauseItem: NSMenuItem?
    private var showOverlayItem: NSMenuItem?
    private var privacyModeItem: NSMenuItem?
    private var speedUpItem: NSMenuItem?
    private var speedDownItem: NSMenuItem?
    private var toggleListenItem: NSMenuItem?
    private var narrowerNotchItem: NSMenuItem?
    private var widerNotchItem: NSMenuItem?
    private var shortcutWarningItem: NSMenuItem?
    private var shortcutWarningDetailItem: NSMenuItem?
    private var shortcutWarningSeparator: NSMenuItem?
    private lazy var hotkeyManager = GlobalHotkeyManager { [weak self] command in
        self?.performShortcut(command)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.loadFromDefaults()
        // Resolve the target display before the first layout so the width range
        // reflects the real screen rather than the fallback.
        model.refreshTargetScreenWidth()
        overlayController = OverlayWindowController(model: model)
        overlayController?.setVisible(model.isOverlayVisible)

#if DEBUG
        ScreenSelectionSelfTests.run()
        ScriptPositionSelfTests.run()
        ScriptTextMapperSelfTests.run()
        ScriptQuoteLocatorSelfTests.run()
        IncrementalJSONSelfTests.run()
        AIStructuredAnswerSelfTests.run()
        ListenHistorySelfTests.run()
        SpeechLocaleSelfTests.run()
        ScriptLibrarySelfTests.run()
        SSESelfTests.run()
        QuestionGateSelfTests.run()
        AnswerCacheSelfTests.run()
        OverlayGeometrySelfTests.run()
        runShortcutSelfChecks()
#endif

        setupEditMenu()
        wireModel()
        hotkeyManager.registerAll()
        setupStatusBar()
        installEditKeyHandler()

        // Debug affordance: `notchprompt --open-settings` opens the settings
        // window at launch, which is the only way to exercise the UI from a
        // script or a screenshot, since the app has no dock icon.
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            openMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveToDefaults()
        hotkeyManager.unregisterAll()
        cancellables.removeAll()
    }

    private func wireModel() {
        model.$privacyModeEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                // Enforce always-on: if something flips it to false, snap back to true and keep .none
                if !enabled {
                    Task { @MainActor in self?.model.privacyModeEnabled = true }
                }
                self?.overlayController?.setPrivacyMode(true)
            }
            .store(in: &cancellables)
        
        model.$isOverlayVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] isVisible in
                self?.overlayController?.setVisible(isVisible)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(model.$overlayWidth, model.$overlayHeight)
            .removeDuplicates { lhs, rhs in
                Int(lhs.0) == Int(rhs.0) && Int(lhs.1) == Int(rhs.1)
            }
            .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.overlayController?.reposition()
            }
            .store(in: &cancellables)

        model.$selectedScreenID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.reposition()
            }
            .store(in: &cancellables)

        // Temporary height changes (AI setup panel) never touch persisted settings.
        model.$transientOverlayHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.overlayController?.reposition()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
#if DEBUG
                print("[Notchprompt] didChangeScreenParametersNotification")
#endif
                self?.model.refreshTargetScreenWidth()
                self?.overlayController?.reposition()
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            model.$script.map { _ in () }.eraseToAnyPublisher(),
            model.$isRunning.map { _ in () }.eraseToAnyPublisher(),
            model.$privacyModeEnabled.map { _ in () }.eraseToAnyPublisher(),
            model.$speedPointsPerSecond.map { _ in () }.eraseToAnyPublisher(),
            model.$fontSize.map { _ in () }.eraseToAnyPublisher(),
            model.$overlayWidth.map { _ in () }.eraseToAnyPublisher(),
            model.$overlayHeight.map { _ in () }.eraseToAnyPublisher(),
            model.$countdownSeconds.map { _ in () }.eraseToAnyPublisher(),
            model.$countdownBehavior.map { _ in () }.eraseToAnyPublisher(),
            model.$scrollMode.map { _ in () }.eraseToAnyPublisher(),
            model.$selectedScreenID.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.model.saveToDefaults()
        }
        .store(in: &cancellables)
    }

    private func setupEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        if let mainMenu = NSApp.mainMenu {
            mainMenu.addItem(editMenuItem)
        } else {
            let mainMenu = NSMenu()
            mainMenu.addItem(editMenuItem)
            NSApp.mainMenu = mainMenu
        }
    }

    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "NP"
        item.button?.toolTip = "Notchprompt"

        let menu = NSMenu()

        let startPause = NSMenuItem(
            title: "Start/Pause",
            action: #selector(toggleRunning),
            keyEquivalent: ShortcutCommand.startPause.keyEquivalent
        )
        startPause.target = self
        startPause.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(startPause)
        startPauseItem = startPause

        let reset = NSMenuItem(
            title: "Reset Scroll",
            action: #selector(resetScroll),
            keyEquivalent: ShortcutCommand.reset.keyEquivalent
        )
        reset.target = self
        reset.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(reset)

        let jumpBack = NSMenuItem(
            title: "Jump Back 5s",
            action: #selector(jumpBack),
            keyEquivalent: ShortcutCommand.jumpBack.keyEquivalent
        )
        jumpBack.target = self
        jumpBack.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(jumpBack)

        let privacyMode = NSMenuItem(
            title: "Privacy Mode",
            action: #selector(togglePrivacyMode),
            keyEquivalent: ShortcutCommand.togglePrivacy.keyEquivalent
        )
        privacyMode.target = self
        privacyMode.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(privacyMode)
        privacyModeItem = privacyMode

        let showOverlay = NSMenuItem(
            title: "Show Overlay",
            action: #selector(toggleOverlayVisibility),
            keyEquivalent: ShortcutCommand.toggleOverlay.keyEquivalent
        )
        showOverlay.target = self
        showOverlay.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(showOverlay)
        showOverlayItem = showOverlay

        let speedUp = NSMenuItem(
            title: "Increase Speed",
            action: #selector(increaseSpeed),
            keyEquivalent: ShortcutCommand.speedUp.keyEquivalent
        )
        speedUp.target = self
        speedUp.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(speedUp)
        speedUpItem = speedUp

        let speedDown = NSMenuItem(
            title: "Decrease Speed",
            action: #selector(decreaseSpeed),
            keyEquivalent: ShortcutCommand.speedDown.keyEquivalent
        )
        speedDown.target = self
        speedDown.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(speedDown)
        speedDownItem = speedDown

        menu.addItem(.separator())

        let toggleListen = NSMenuItem(
            title: "Listen for Question",
            action: #selector(toggleListen),
            keyEquivalent: ShortcutCommand.toggleListen.keyEquivalent
        )
        toggleListen.target = self
        toggleListen.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(toggleListen)
        toggleListenItem = toggleListen

        let narrower = NSMenuItem(
            title: "Narrower Notch",
            action: #selector(narrowerNotch),
            keyEquivalent: ShortcutCommand.narrowerNotch.keyEquivalent
        )
        narrower.target = self
        narrower.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(narrower)
        narrowerNotchItem = narrower

        let wider = NSMenuItem(
            title: "Wider Notch",
            action: #selector(widerNotch),
            keyEquivalent: ShortcutCommand.widerNotch.keyEquivalent
        )
        wider.target = self
        wider.keyEquivalentModifierMask = shortcutModifiers
        menu.addItem(wider)
        widerNotchItem = wider

        refreshShortcutWarningItems(in: menu)

        menu.addItem(.separator())

        let openScriptEditor = NSMenuItem(title: "Script Editor…", action: #selector(openScriptEditorWindow), keyEquivalent: "")
        openScriptEditor.target = self
        menu.addItem(openScriptEditor)

        installScriptsSubmenu(in: menu)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Settings…", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Notchprompt", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    /// Build the "Scripts" submenu from the current library contents.
    private func makeScriptsMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.title = "Scripts"

        let library = ScriptLibrary.shared
        let current = model.script

        if library.scripts.isEmpty {
            let empty = NSMenuItem(title: "No saved scripts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for script in library.scripts {
                let item = NSMenuItem(
                    title: script.name,
                    action: #selector(loadScript(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = script.id.uuidString
                item.toolTip = script.shortSummary
                if script.text == current { item.state = .on }
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Scripts…", action: #selector(openMainWindow), keyEquivalent: "")
        manage.target = self
        submenu.addItem(manage)

        return submenu
    }

    private func installScriptsSubmenu(in menu: NSMenu) {
        let container = NSMenuItem(title: "Scripts", action: nil, keyEquivalent: "")
        container.submenu = makeScriptsMenu()
        menu.addItem(container)
    }

    @objc private func loadScript(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let script = ScriptLibrary.shared.scripts.first(where: { $0.id == id })
        else { return }
        model.script = script.text
        model.resetScroll()
    }

    // MARK: - Edit key handler (Cmd+C/V/X/A/Z bypass for menu-bar apps)

    private func installEditKeyHandler() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command ||
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] else {
                return event
            }
            let key = event.charactersIgnoringModifiers ?? ""
            let action: Selector? = switch key {
            case "x": #selector(NSText.cut(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z" where event.modifierFlags.contains(.shift): NSSelectorFromString("redo:")
            case "z": NSSelectorFromString("undo:")
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: nil) {
                return nil
            }
            return event
        }
    }

    // MARK: - Actions

    @objc private func toggleRunning() {
        model.toggleRunning()
    }

    @objc private func resetScroll() {
        model.resetScroll()
    }

    @objc private func jumpBack() {
        model.jumpBack(seconds: 5)
    }

    @objc private func togglePrivacyMode() {
        // Enforced hidden-from-capture: never allow sharingType to become .readOnly.
        // Keep model true and re-assert .none on the window.
        model.privacyModeEnabled = true
        overlayController?.setPrivacyMode(true)
    }
    
    @objc private func toggleOverlayVisibility() {
        model.isOverlayVisible.toggle()
    }

    @objc private func increaseSpeed() {
        model.adjustSpeed(delta: PrompterModel.speedStep)
    }

    @objc private func decreaseSpeed() {
        model.adjustSpeed(delta: -PrompterModel.speedStep)
    }

    @objc private func toggleListen() {
        ListenModel.shared.toggleListen()
    }

    @objc private func narrowerNotch() {
        model.adjustOverlayWidth(by: -OverlayGeometry.widthStep)
    }

    @objc private func widerNotch() {
        model.adjustOverlayWidth(by: OverlayGeometry.widthStep)
    }

    @objc func openMainWindowFromOverlay() {
        openMainWindow()
    }

    @objc private func openMainWindow() {
        Task { @MainActor in
            if settingsWindowController == nil {
                settingsWindowController = SettingsWindowController()
            }
            settingsWindowController?.show()
        }
    }
    
    @objc private func openScriptEditorWindow() {
        Task { @MainActor in
            if scriptEditorWindowController == nil {
                scriptEditorWindowController = ScriptEditorWindowController()
            }
            scriptEditorWindowController?.show()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func performShortcut(_ command: ShortcutCommand) {
        switch command {
        case .startPause:
            model.toggleRunning()
        case .reset:
            model.resetScroll()
        case .jumpBack:
            model.jumpBack(seconds: 5)
        case .togglePrivacy:
            // Enforced hidden-from-capture: shortcut keeps it enabled
            model.privacyModeEnabled = true
            overlayController?.setPrivacyMode(true)
        case .toggleOverlay:
            model.isOverlayVisible.toggle()
        case .speedUp:
            model.adjustSpeed(delta: PrompterModel.speedStep)
        case .speedDown:
            model.adjustSpeed(delta: -PrompterModel.speedStep)
        case .toggleListen:
            ListenModel.shared.toggleListen()
        case .narrowerNotch:
            model.adjustOverlayWidth(by: -OverlayGeometry.widthStep)
        case .widerNotch:
            model.adjustOverlayWidth(by: OverlayGeometry.widthStep)
        }
    }

    private func refreshShortcutWarningItems(in menu: NSMenu) {
        if let shortcutWarningItem {
            menu.removeItem(shortcutWarningItem)
            self.shortcutWarningItem = nil
        }
        if let shortcutWarningDetailItem {
            menu.removeItem(shortcutWarningDetailItem)
            self.shortcutWarningDetailItem = nil
        }
        if let shortcutWarningSeparator {
            menu.removeItem(shortcutWarningSeparator)
            self.shortcutWarningSeparator = nil
        }

        let unavailable = hotkeyManager.failedRegistrations
        guard !unavailable.isEmpty else { return }

        if unavailable.count == 1, let first = unavailable.first {
            let warning = NSMenuItem(
                title: "Shortcut unavailable: \(first.displayShortcut) (in use by another app)",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.insertItem(warning, at: 0)
            shortcutWarningItem = warning
        } else {
            let warning = NSMenuItem(
                title: "Shortcuts unavailable (\(unavailable.count))",
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.insertItem(warning, at: 0)
            shortcutWarningItem = warning

            let detail = unavailable
                .map(\.displayShortcut)
                .joined(separator: ", ")
            let detailItem = NSMenuItem(
                title: "In use by another app: \(detail)",
                action: nil,
                keyEquivalent: ""
            )
            detailItem.isEnabled = false
            menu.insertItem(detailItem, at: 1)
            shortcutWarningDetailItem = detailItem
        }

        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: unavailable.count == 1 ? 1 : 2)
        shortcutWarningSeparator = separator
    }

#if DEBUG
    private func runShortcutSelfChecks() {
        GlobalHotkeyManager.runSelfChecks()
    }
#endif

    // MARK: - Menu Validation

    /// Rebuild the Scripts submenu whenever the status menu opens, so a script
    /// saved during this session shows up without a relaunch.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let container = menu.items.first(where: { $0.title == "Scripts" }) else { return }
        container.submenu = makeScriptsMenu()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem === startPauseItem {
            menuItem.title = model.isRunning ? "Pause" : "Start"
            return true
        }

        if menuItem === privacyModeItem {
            // Enforced: always hidden from capture/recording (SharingType.none)
            menuItem.title = "Hidden from Capture (Enforced)"
            menuItem.state = .on
            menuItem.toolTip = "Overlay is always NSWindow.SharingType.none — never appears in screen recordings or shared windows (re-asserted on show/reposition)."
            return true
        }
        
        if menuItem === showOverlayItem {
            menuItem.state = model.isOverlayVisible ? .on : .off
            return true
        }

        if menuItem === speedUpItem || menuItem === speedDownItem {
            return true
        }

        if menuItem === narrowerNotchItem {
            menuItem.title = "Narrower Notch  (\(Int(model.overlayWidth))pt)"
            return true
        }

        if menuItem === widerNotchItem {
            menuItem.title = "Wider Notch  (\(Int(model.overlayWidth))pt)"
            return true
        }

        if menuItem === toggleListenItem {
            let lm = ListenModel.shared
            if lm.isListening {
                menuItem.title = "Stop Listening"
            } else {
                // Show dynamic title based on last state
                switch lm.state {
                case .thinking: menuItem.title = "Listening… (Thinking)"
                case .answering: menuItem.title = "Listen Again"
                case .error: menuItem.title = "Retry Listen"
                default: menuItem.title = "Listen for Question"
                }
            }
            return true
        }

        return true
    }
}
