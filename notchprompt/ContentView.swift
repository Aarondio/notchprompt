//
//  ContentView.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import SwiftUI
import AppKit
import CoreGraphics

struct ContentView: View {
    @ObservedObject private var model = PrompterModel.shared
    @ObservedObject private var listen = ListenModel.shared
    @ObservedObject private var aiConfig = AIConfig.shared
    @State private var testStatus: String?
    @State private var fallbackTestStatus: String?
    @State private var isTesting = false
    @State private var isTestingFallback = false
    @State private var cachedCount = AnswerCache.shared.count

    private let rowLabelWidth: CGFloat = 164
    private let valueWidth: CGFloat = 56

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                playbackSection
                listenAISection
                appearanceSection
                displaySection
                privacySection
                shortcutsSection
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(ScrollBounceBehaviorModifier())
        .frame(minWidth: 640, minHeight: 620)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.title3.weight(.semibold))
            Text("Configure playback, appearance, and display behavior for the overlay.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 2)
    }

    private var playbackSection: some View {
        SettingsSection(title: "Playback") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    title: "Speed",
                    valueText: "\(Int(model.speedPointsPerSecond))",
                    slider: Slider(value: $model.speedPointsPerSecond, in: 10...300, step: 5)
                )

                HStack(alignment: .firstTextBaseline) {
                    Text("Scroll mode")
                        .frame(width: rowLabelWidth, alignment: .leading)
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.scrollMode },
                            set: { model.setScrollMode($0) }
                        )
                    ) {
                        Text("Infinite").tag(PrompterModel.ScrollMode.infinite)
                        Text("Stop at end").tag(PrompterModel.ScrollMode.stopAtEnd)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                HStack {
                    Text("Countdown")
                        .frame(width: rowLabelWidth, alignment: .leading)
                    Picker("", selection: $model.countdownBehavior) {
                        ForEach(PrompterModel.CountdownBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.label).tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer(minLength: 0)
                }

                sliderRow(
                    title: "Countdown duration",
                    valueText: "\(model.countdownSeconds)s",
                    slider: Slider(
                        value: Binding(
                            get: { Double(model.countdownSeconds) },
                            set: { model.countdownSeconds = Int($0.rounded()) }
                        ),
                        in: 0...10,
                        step: 1
                    )
                    .disabled(model.countdownBehavior == .never)
                )
            }
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    title: "Font size",
                    valueText: "\(Int(model.fontSize))",
                    slider: Slider(value: $model.fontSize, in: 12...40, step: 1)
                )

                sliderRow(
                    title: "Overlay width",
                    valueText: "\(Int(model.overlayWidth))",
                    slider: Slider(value: $model.overlayWidth, in: 400...1200, step: 10)
                )

                sliderRow(
                    title: "Overlay height",
                    valueText: "\(Int(model.overlayHeight))",
                    slider: Slider(value: $model.overlayHeight, in: 120...300, step: 2)
                )
            }
        }
    }

    private var displaySection: some View {
        SettingsSection(title: "Display") {
            HStack {
                Text("Show overlay on")
                    .frame(width: rowLabelWidth, alignment: .leading)
                Picker("", selection: $model.selectedScreenID) {
                    Text("Auto (Built-in)").tag(CGDirectDisplayID(0))
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Text(screen.localizedName).tag(screenID(for: screen))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer(minLength: 0)
            }
        }
    }

    private var listenAISection: some View {
        SettingsSection(title: "Listen & AI  —  Background Q&A") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tap the mic in the notch (or ⌥⌘L) to capture a background question. Transcript is sent to your AI model and the answer is shown in the notch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Listen behavior toggles
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-send after pause ( hands-free )", isOn: $listen.autoSendOnSilence)
                    Text("If on, a pause ends the utterance and sends it. Turn off to tap the mic again to send.")
                        .font(.caption2).foregroundStyle(.secondary)

                    sliderRow(
                        title: "Pause before sending",
                        valueText: String(format: "%.1fs", listen.silenceThreshold),
                        slider: Slider(value: $listen.silenceThreshold, in: 0.6...3.0, step: 0.1)
                    )
                    Text("Lower is snappier but may cut you off mid-sentence. Raise it in a noisy room.")
                        .font(.caption2).foregroundStyle(.secondary)

                    Toggle("Skip things that aren't questions", isOn: $listen.questionGateEnabled)
                    Text("Small talk and filler are not sent to the AI, which avoids pointless requests. You can always force one through.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if listen.questionGateEnabled {
                        sliderRow(
                            title: "Always send if longer than",
                            valueText: "\(listen.questionGateMinWords) words",
                            slider: Slider(
                                value: Binding(
                                    get: { Double(listen.questionGateMinWords) },
                                    set: { listen.questionGateMinWords = Int($0.rounded()) }
                                ),
                                in: 3...15,
                                step: 1
                            )
                        )
                    }

                    Toggle("Continuous listening (interview mode)", isOn: $listen.continuousListening)
                    Text("Keeps listening after each answer for the next question.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("Show answer card in notch", isOn: $listen.showAnswerInNotch)
                    Toggle("Stream answers as they arrive", isOn: $listen.streamAnswers)
                    Text("Shows the first words in about a second instead of waiting for the whole answer. Turn off if your provider streams poorly.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()

                // AI Provider
                VStack(alignment: .leading, spacing: 8) {
                    AIProviderEditor(
                        title: "Primary provider",
                        icon: "1.circle.fill",
                        tint: .blue,
                        baseURL: $aiConfig.baseURLString,
                        model: $aiConfig.modelName,
                        apiKey: $aiConfig.apiKey,
                        selectedPreset: aiConfig.primaryPreset,
                        onSelectPreset: { aiConfig.applyPrimaryPreset($0) },
                        compact: false,
                        pageLabelWidth: rowLabelWidth
                    )
                    Text("Pick a provider, then paste its API key. Everything is stored locally in UserDefaults and used immediately.")
                        .font(.caption2).foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button {
                            Task { await runAIQuickTest() }
                        } label: {
                            if isTesting { ProgressView().scaleEffect(0.6) } else { Text("Test AI connection") }
                        }
                        .disabled(aiConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                        .controlSize(.small)

                        if let s = testStatus {
                            Text(s).font(.caption).foregroundStyle(s.contains("OK") || s.contains("✓") ? .green : .orange).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Prompt").font(.caption.weight(.semibold))
                        TextEditor(text: $aiConfig.systemPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 74)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                        Button("Restore default") { aiConfig.systemPrompt = AIConfig.defaultSystemPrompt }
                            .controlSize(.small)
                    }

                    Toggle("Include script as context", isOn: $aiConfig.includeScriptAsContext)
                    Text("Sends up to 6k chars of your script with each question so answers stay on-message.")
                        .font(.caption2).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        HStack {
                            Text("Temperature").frame(width: rowLabelWidth, alignment: .leading)
                            Slider(value: $aiConfig.temperature, in: 0...1, step: 0.1)
                            Text(String(format: "%.1f", aiConfig.temperature)).frame(width: 30, alignment: .trailing).foregroundStyle(.secondary).font(.caption.monospaced())
                        }
                    }
                    HStack {
                        Text("Max tokens").frame(width: rowLabelWidth, alignment: .leading)
                        Slider(value: Binding(get: { Double(aiConfig.maxTokens) }, set: { aiConfig.maxTokens = Int($0.rounded()) }), in: 80...800, step: 10)
                        Text("\(aiConfig.maxTokens)").frame(width: 40, alignment: .trailing).foregroundStyle(.secondary).font(.caption.monospaced())
                    }
                }

                Divider()

                // Answer cache
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Re-use answers to repeated questions", isOn: $aiConfig.answerCacheEnabled)
                    Text("Objections and FAQs come up on every call. Cached answers return instantly and cost nothing.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Remember cached answers on disk", isOn: $aiConfig.answerCachePersistToDisk)
                    Text("Off by default. Writing to disk keeps the cache between launches but leaves a record of what was discussed, which is why it is opt-in.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text("Cached answers: \(cachedCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear cache") {
                            AnswerCache.shared.clear()
                            cachedCount = 0
                        }
                        .controlSize(.small)
                        .disabled(cachedCount == 0)
                    }
                }

                Divider()

                // Fallback provider (DeepSeek)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable fallback — auto-retry with second provider", isOn: $aiConfig.fallbackEnabled)
                    Text("If primary fails (rate limit, 5xx, network, invalid key), Notchprompt retries once with the fallback. Recommended: DeepSeek as fallback.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        AIProviderEditor(
                            title: "Fallback provider",
                            icon: "2.circle.fill",
                            tint: .purple,
                            baseURL: $aiConfig.fallbackBaseURLString,
                            model: $aiConfig.fallbackModelName,
                            apiKey: $aiConfig.fallbackApiKey,
                            selectedPreset: aiConfig.fallbackPreset,
                            onSelectPreset: { aiConfig.applyFallbackPreset($0) },
                            compact: false,
                            disabled: !aiConfig.fallbackEnabled,
                            pageLabelWidth: rowLabelWidth
                        )
                        Text("Blank fallback key = no fallback. Used only when the primary fails and the toggle above is on.")
                            .font(.caption2).foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button {
                                Task { await runFallbackTest() }
                            } label: {
                                if isTestingFallback { ProgressView().scaleEffect(0.6) } else { Text("Test fallback") }
                            }
                            .disabled(!aiConfig.fallbackEnabled || aiConfig.fallbackApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingFallback)
                            .controlSize(.small)
                            if let s = fallbackTestStatus {
                                Text(s).font(.caption).foregroundStyle(s.contains("OK") || s.contains("✓") ? .green : .orange).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                    .opacity(aiConfig.fallbackEnabled ? 1 : 0.55)
                }

                if !listen.history.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Recent Q&A").font(.caption.weight(.semibold))
                            Spacer()
                            Button("Clear") { listen.clearHistory() }.controlSize(.small)
                        }
                        ForEach(Array(listen.history.prefix(3).enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Q: \(item.question)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 4)
                                    if let p = item.provider {
                                        Text(p).font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2).background(p.lowercased().contains("deepseek") ? Color.purple.opacity(0.7) : Color.blue.opacity(0.7), in: Capsule())
                                    }
                                }
                                Text(item.answer).font(.caption).lineLimit(2)
                            }
                            .padding(6)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private func runAIQuickTest() async {
        isTesting = true
        testStatus = "Testing…"
        do {
            let ans = try await AIService.shared.answer(question: "Say 'Notchprompt OK' if you can hear me. Keep answer to 5 words.", scriptContext: nil)
            testStatus = "✓ OK: \(ans.prefix(60)) (chain: primary → DeepSeek fallback if needed)"
        } catch {
            testStatus = "Error: \(error.localizedDescription.prefix(120))"
        }
        isTesting = false
    }

    private func runFallbackTest() async {
        isTestingFallback = true
        fallbackTestStatus = "Testing fallback…"
        do {
            let ans = try await AIService.shared.testFallbackConnection()
            fallbackTestStatus = "✓ Fallback OK: \(ans.prefix(60))"
        } catch {
            fallbackTestStatus = "Error: \(error.localizedDescription.prefix(120))"
        }
        isTestingFallback = false
    }

    private var privacySection: some View {
        SettingsSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show overlay", isOn: $model.isOverlayVisible)
                // Enforced: notch is never capturable (NSWindow.SharingType.none on every show/reposition).
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                    Toggle("Hidden from screen recordings & screen sharing", isOn: .constant(true))
                        .disabled(true)
                        .help("Enforced: Overlay uses NSWindow.SharingType.none and is re-asserted on every show/reposition — it will not appear in QuickTime, ScreenCaptureKit, Zoom/Meet shares, etc.")
                }
                Text("Enforced — the notch overlay is never included in screen captures, recordings, or shared windows (best-effort OS guarantee; re-asserted on show/reposition).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Show overlay still controls local visibility; capture exclusion is always on.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shortcutsSection: some View {
        SettingsSection(title: "Keyboard Shortcuts") {
            VStack(alignment: .leading, spacing: 6) {
                shortcutRow("Option+Command+P", "Start / Pause")
                shortcutRow("Option+Command+R", "Reset scroll")
                shortcutRow("Option+Command+J", "Jump back 5 seconds")
                shortcutRow("Option+Command+H", "Toggle privacy mode")
                shortcutRow("Option+Command+O", "Toggle overlay visibility")
                shortcutRow("Option+Command+=", "Increase speed")
                shortcutRow("Option+Command+-", "Decrease speed")
                shortcutRow("Option+Command+L", "Listen — toggle mic / send to AI")
            }
        }
    }

    @ViewBuilder
    private func sliderRow<SliderView: View>(
        title: String,
        valueText: String,
        slider: SliderView
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: rowLabelWidth, alignment: .leading)
            slider
            Text(valueText)
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 175, alignment: .leading)
            Text(action)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    private func screenID(for screen: NSScreen) -> CGDirectDisplayID {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return CGDirectDisplayID(n.uint32Value)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDisplayName("Default")

        ContentView()
            .frame(width: 620, height: 360)
            .previewDisplayName("Compact Height")
    }
}
#endif

private struct ScrollBounceBehaviorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}
