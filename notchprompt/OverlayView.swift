//
//  OverlayView.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import SwiftUI

private extension Color {
    /// `#000000` (darkest black for seamless notch blending)
    static let notchBlack = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1.0)
}

/// MacBook-style notch contour:
/// - flat top edge with square top corners
/// - straight side walls
/// - rounded lower corners
private struct AppleNotchShape: InsettableShape {
    /// Lower corner radius relative to height.
    var bottomCornerRadiusRatio: CGFloat = 0.18
    /// Portion of total height used by the straight side wall.
    var sideWallDepthRatio: CGFloat = 0.82
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }

        let w = r.width
        let h = r.height

        // sideWallDepthRatio controls how much vertical wall exists before lower arcs.
        let depthRatio = max(0.60, min(sideWallDepthRatio, 0.95))
        let lowerArcStartY = r.minY + (h * depthRatio)
        let maxBottomRadiusFromDepth = max(0, r.maxY - lowerArcStartY)
        let maxBottomRadiusFromWidth = w * 0.5
        let targetBottomRadius = h * bottomCornerRadiusRatio
        let bottomRadius = max(
            0,
            min(targetBottomRadius, min(maxBottomRadiusFromDepth, maxBottomRadiusFromWidth))
        )

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))

        // Right side wall into large lower corner.
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottomRadius))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.maxX - bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX + bottomRadius, y: r.maxY))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.minX + bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()

        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var s = self
        s.insetAmount += amount
        return s
    }
}

struct OverlayView: View {
    @ObservedObject var model: PrompterModel
    @ObservedObject private var listen = ListenModel.shared

    var body: some View {
        // Ratio-driven contour tuned to Apple notch geometry and scaled to the
        // current overlay dimensions.
        let shape = AppleNotchShape()
        let hideTopStrokeHeight: CGFloat = 2

        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(shape)
                // Blur can brighten the surface; keep it effectively off for notch matching.
                .opacity(0.0)

            shape
                .fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: model.backgroundOpacity))

            shape
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                // Hard-cut the stroke off at the very top so the edge blends into the notch.
                .mask(
                    VStack(spacing: 0) {
                        Color.clear.frame(height: hideTopStrokeHeight)
                        Color.white
                    }
                )

            // The scroller is hard-clipped (so text truly "cuts off") and we add
            // subtle blur bands at the top/bottom to soften the exit.
            ScrollingTextView(
                text: model.script,
                fontSize: CGFloat(model.fontSize),
                speedPointsPerSecond: model.speedPointsPerSecond,
                isRunning: model.isRunning,
                hasStartedSession: model.hasStartedSession,
                resetToken: model.resetToken,
                jumpBackToken: model.jumpBackToken,
                jumpBackDistancePoints: model.jumpBackDistancePoints,
                manualScrollToken: model.manualScrollToken,
                manualScrollDeltaPoints: model.manualScrollDeltaPoints,
                fadeFraction: CGFloat(model.edgeFadeFraction),
                backgroundOpacity: model.backgroundOpacity,
                isHovering: false,
                scrollMode: model.scrollMode,
                onReachedEnd: {
                    if model.isRunning {
                        model.markReachedEndInStopMode()
                    }
                },
                position: ScriptPositionModel.shared
            )
            .padding(.horizontal, 18)
            .padding(.top, 58)
            .padding(.bottom, 16)
            .clipShape(Rectangle())
            .overlay {
                TrackpadScrollCaptureView { delta in
                    model.handleManualScroll(deltaPoints: delta)
                }
            }
            
            if !model.isCountingDown {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            OverlayControlButton(
                                symbol: (model.isRunning || model.isCountingDown) ? "hand.draw.fill" : "play.fill"
                            ) {
                                model.switchPlaybackModeFromOverlayControl()
                            }
                            .help((model.isRunning || model.isCountingDown) ? "Pause and switch to manual trackpad scroll" : "Start auto scroll")
                            
                            OverlayControlButton(symbol: "gobackward.5") {
                                model.jumpBack(seconds: 5)
                            }
                            .help("Jump back 5 seconds")

                            ListenControlButton(listen: listen)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        
                        Spacer(minLength: 4)
                        
                        HStack(spacing: 6) {
                            OverlayControlButton(symbol: "doc.on.clipboard") {
                                if let text = NSPasteboard.general.string(forType: .string) {
                                    model.pasteScript(text)
                                }
                            }
                            .help("Paste script from clipboard")

                            OverlayControlButton(symbol: "trash") {
                                model.script = ""
                            }
                            .help("Clear script")

                            OverlayControlButton(symbol: "minus", repeatWhilePressed: true) {
                                model.adjustSpeed(delta: -PrompterModel.speedStep)
                            }
                            .help("Decrease speed")

                            OverlayControlButton(symbol: "plus", repeatWhilePressed: true) {
                                model.adjustSpeed(delta: PrompterModel.speedStep)
                            }
                            .help("Increase speed")

                            OverlayControlButton(symbol: "gearshape", isActive: listen.isAISetupVisible) {
                                listen.toggleAISetup()
                            }
                            .help("AI providers & API keys — OpenAI, DeepSeek, Groq, OpenRouter…")

                            OverlayControlButton(symbol: "xmark") {
                                NSApp.terminate(nil)
                            }
                            .help("Quit Notchprompt")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            // —— Bottom panel: AI provider setup takes priority over the answer card ——
            if listen.isAISetupVisible {
                VStack {
                    Spacer()
                    NotchAISetupCard(listen: listen)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .allowsHitTesting(true)
            } else if listen.showAnswerInNotch {
                VStack {
                    Spacer()
                    ListenAnswerCard(listen: listen)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .allowsHitTesting(true)
            }

            if model.isCountingDown {
                ZStack {
                    Color.black.opacity(0.92)
                    Text("\(model.countdownRemaining)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
        }
        .frame(width: model.overlayWidth, height: model.effectiveOverlayHeight)
    }
}

// MARK: - Listen UI

private struct ListenControlButton: View {
    @ObservedObject var listen: ListenModel

    private var symbol: String {
        switch listen.state {
        case .idle: return "mic.fill"
        case .requestingPermission: return "mic.badge.plus"
        case .listening: return "waveform"
        case .thinking: return "hourglass"
        case .gateSuppressed: return "questionmark.bubble.dotted"
        case .streaming: return "ellipsis.bubble.fill"
        case .answering: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var isBusy: Bool {
        switch listen.state {
        case .listening, .thinking, .requestingPermission: return true
        default: return false
        }
    }

    var body: some View {
        Button {
            listen.toggleListen()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(listen.isListening ? Color.red : Color.white)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(
            OverlayCircleButtonStyle(
                isActive: isBusy,
                repeatWhilePressed: false,
                repeatAction: nil
            )
        )
        .help(helpText)
    }

    private var helpText: String {
        switch listen.state {
        case .idle: return "Listen for a background question (\u{2325}\u{2318}L)"
        case .requestingPermission: return "Requesting mic permission\u{2026}"
        case .listening: return "Listening\u{2026} tap again to send to AI, or wait for auto-send"
        case .thinking(let q): return "Thinking about: \(q.prefix(60))"
        case .gateSuppressed: return "Skipped — didn't sound like a question"
        case .streaming: return "Answer is streaming in…"
        case .answering: return "Answer ready \u{2014} tap to listen for the next question"
        case .error(let m): return m
        }
    }
}

private struct ListenAnswerCard: View {
    @ObservedObject var listen: ListenModel

    var body: some View {
        Group {
            switch listen.state {
            case .idle, .requestingPermission:
                EmptyView()
            case .listening(let transcript):
                card {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.62).tint(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Listening…")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                                .textCase(.uppercase)
                            Text(transcript.isEmpty ? "Say the question… background speech is captured" : transcript)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(transcript.isEmpty ? 0.7 : 0.95))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 6)
                        Button("Stop") { listen.toggleListen() }
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.red.opacity(0.85), in: Capsule())
                    }
                }
            case .thinking(let q):
                card {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.62).tint(.white)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Thinking…")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .textCase(.uppercase)
                            Text(q).font(.system(size: 11, weight: .regular, design: .rounded)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        }
                        Spacer()
                    }
                }
            case .gateSuppressed(let text):
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "questionmark.bubble.dotted")
                                .font(.system(size: 10))
                                .foregroundStyle(.yellow.opacity(0.9))
                            Text("Not sent").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7)).textCase(.uppercase)
                            Spacer()
                            Button { listen.dismissAnswer() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7)) }
                                .buttonStyle(.plain)
                        }
                        Text("Didn't sound like a question, so no request was made.")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(text)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Button { listen.sendSuppressedAnyway(text) } label: {
                                Label("Send anyway", systemImage: "paperplane.fill")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(ListenCardButtonStyle())

                            Button { listen.startListening() } label: {
                                Text("Keep listening").font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(ListenCardButtonStyle())

                            Spacer(minLength: 4)
                        }
                    }
                }
            case .streaming(let partial, let reasoning):
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.5).frame(width: 10, height: 10).tint(.white)
                            Text("Answering…").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.65)).textCase(.uppercase)
                            if let provider = listen.lastProvider ?? AIService.shared.lastSuccessfulProvider {
                                Text(provider).font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(provider.lowercased().contains("deepseek") ? Color.purple.opacity(0.75) : Color.blue.opacity(0.75), in: Capsule())
                            }
                            Spacer()
                            if !reasoning.isEmpty {
                                Text("reasoning…")
                                    .font(.system(size: 8, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                        }
                        Text(partial)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: false)
                        // Blinking caret signals the answer is still arriving.
                        Text("▌").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            case .answering(let ans):
                card {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.yellow.opacity(0.9))
                            Text("Suggested answer").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6)).textCase(.uppercase)
                            if listen.lastAnswerWasCached {
                                Text("cached")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.75), in: Capsule())
                                    .help("Reused from the local cache — no request was made")
                            } else if let provider = listen.lastProvider {
                                Text(provider).font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(provider.lowercased().contains("deepseek") ? Color.purple.opacity(0.75) : Color.blue.opacity(0.75), in: Capsule())
                                    .help("Answered via \(provider)\(provider.lowercased().contains("deepseek") && AIConfig.shared.fallbackEnabled ? " (fallback)" : "")")
                            }
                            Spacer()
                            Button { listen.dismissAnswer() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7)).frame(width: 18, height: 18).background(Color.white.opacity(0.12), in: Circle()) }
                                .buttonStyle(.plain).help("Dismiss")
                        }
                        Text(ans)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        if !listen.lastQuestion.isEmpty {
                            Text("Q: \(listen.lastQuestion)")
                                .font(.system(size: 10, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Button { listen.copyAnswerToClipboard() } label: {
                                Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(ListenCardButtonStyle())

                            Button { listen.pushAnswerToScript() } label: {
                                Label("To script", systemImage: "arrow.down.doc").font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(ListenCardButtonStyle())

                            Button { listen.refreshLastAnswer() } label: {
                                Label("Re-ask", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(ListenCardButtonStyle())
                            .help("Ask the AI again, ignoring the cached answer")

                            Spacer(minLength: 4)

                            Button("Listen again") { listen.startListening() }
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.white.opacity(0.14), in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                }
            case .error(let msg):
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10))
                            Text("Listen error").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.7)).textCase(.uppercase)
                            Spacer()
                            Button { listen.dismissAnswer() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7)) }
                                .buttonStyle(.plain)
                        }
                        Text(msg).font(.system(size: 11, weight: .regular, design: .rounded)).foregroundStyle(.white.opacity(0.9)).lineLimit(3).fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Button { listen.dismissAnswer() } label: {
                                Text("Dismiss").font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(ListenCardButtonStyle())

                            Button { listen.dismissAnswer(); listen.openAISetup() } label: {
                                Label("AI Providers & Keys", systemImage: "key.fill").font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .buttonStyle(ListenCardButtonStyle())

                            Spacer(minLength: 4)

                            Button { listen.startListening() } label: {
                                Text("Retry").font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.orange.opacity(0.85), in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: listen.state)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
            )
    }
}

/// Notch-native AI provider + API key setup panel (opened by the gear control).
private struct NotchAISetupCard: View {
    @ObservedObject var listen: ListenModel
    @ObservedObject private var aiConfig = AIConfig.shared
    @State private var testStatus: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow.opacity(0.9))
                Text("AI Providers")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                Text("keys stored locally")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Button { listen.closeAISetup() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    AIProviderEditor(
                        title: "Primary",
                        icon: "1.circle.fill",
                        tint: .blue,
                        baseURL: $aiConfig.baseURLString,
                        model: $aiConfig.modelName,
                        apiKey: $aiConfig.apiKey,
                        selectedPreset: aiConfig.primaryPreset,
                        onSelectPreset: { aiConfig.applyPrimaryPreset($0) },
                        compact: true
                    )

                    Divider().overlay(Color.white.opacity(0.10))

                    Toggle(isOn: $aiConfig.fallbackEnabled) {
                        Text("Fallback provider (auto-retry)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .toggleStyle(.switch)
                    .scaleEffect(0.78, anchor: .leading)

                    AIProviderEditor(
                        title: "Fallback",
                        icon: "2.circle.fill",
                        tint: .purple,
                        baseURL: $aiConfig.fallbackBaseURLString,
                        model: $aiConfig.fallbackModelName,
                        apiKey: $aiConfig.fallbackApiKey,
                        selectedPreset: aiConfig.fallbackPreset,
                        onSelectPreset: { aiConfig.applyFallbackPreset($0) },
                        compact: true,
                        disabled: !aiConfig.fallbackEnabled
                    )
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 210)

            if let s = testStatus {
                Text(s)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(s.contains("✓") ? .green : .orange)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button {
                    Task { await runTest() }
                } label: {
                    if isTesting {
                        ProgressView().scaleEffect(0.5).frame(width: 54)
                    } else {
                        Label("Test", systemImage: "bolt.fill").font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                }
                .buttonStyle(ListenCardButtonStyle())
                .disabled(aiConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                Button {
                    NSApp.sendAction(#selector(AppDelegate.openMainWindowFromOverlay), to: nil, from: nil)
                } label: {
                    Text("Full Settings…").font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .buttonStyle(ListenCardButtonStyle())

                Spacer(minLength: 4)

                Button { listen.closeAISetup() } label: {
                    Text("Done").font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.blue.opacity(0.9), in: Capsule())
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        )
    }

    private func runTest() async {
        isTesting = true
        testStatus = "Testing \(aiConfig.providerLabel)…"
        do {
            let ans = try await AIService.shared.testPrimaryConnection()
            testStatus = "✓ \(aiConfig.providerLabel): \(ans.prefix(40))"
        } catch {
            testStatus = "Error: \(error.localizedDescription.prefix(90))"
        }
        isTesting = false
    }
}

private struct ListenCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

private struct OverlayControlButton: View {
    let symbol: String
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    let action: () -> Void

    var body: some View {
        // Use SwiftUI Button (not onLongPressGesture) so we benefit from
        // the macOS 15 click-through fix for non-activating panels (FB13720950).
        Button {
            if !repeatWhilePressed { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(
            OverlayCircleButtonStyle(
                isActive: isActive,
                repeatWhilePressed: repeatWhilePressed,
                repeatAction: action
            )
        )
    }
}

/// Button style that provides press-highlight and optional repeat-while-held.
private struct OverlayCircleButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    var repeatAction: (() -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed || isActive ? 0.18 : 0.10))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .background {
                if repeatWhilePressed {
                    RepeatWhileHeldHelper(
                        isPressed: configuration.isPressed,
                        action: repeatAction ?? {}
                    )
                }
            }
    }
}

/// Zero-size helper that fires an action on press-down and repeats while held.
private struct RepeatWhileHeldHelper: View {
    let isPressed: Bool
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isPressed) { _, pressed in
                if pressed {
                    action()
                    startRepeating()
                } else {
                    stopRepeating()
                }
            }
            .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        stopRepeating()
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            while !Task.isCancelled {
                await MainActor.run { action() }
                try? await Task.sleep(nanoseconds: 85_000_000)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct TrackpadScrollCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        view.onScroll = context.coordinator.handleScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        nsView.onScroll = context.coordinator.handleScroll
    }

    final class Coordinator {
        let onScroll: (CGFloat) -> Void

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func handleScroll(_ event: NSEvent) {
            let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
            let semanticDelta = event.isDirectionInvertedFromDevice ? rawDelta : -rawDelta
            onScroll(semanticDelta)
        }
    }
}

final class ScrollCaptureNSView: NSView {
    var onScroll: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}
