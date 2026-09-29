//
//  AIProviderSetup.swift
//  notchprompt
//
//  Known AI providers (OpenAI-compatible) + a reusable provider/key editor
//  surfaced both in the notch and in the Settings window.
//

import SwiftUI
import AppKit

// MARK: - Preset

struct AIProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let baseURL: String
    let defaultModel: String
    let models: [String]
    let keyURL: String
    let keyPlaceholder: String

    static let custom = AIProviderPreset(
        id: "custom",
        name: "Custom (OpenAI-compatible)",
        shortName: "Custom",
        baseURL: "",
        defaultModel: "",
        models: [],
        keyURL: "",
        keyPlaceholder: "sk-…"
    )

    static let all: [AIProviderPreset] = [
        AIProviderPreset(
            id: "openai", name: "OpenAI", shortName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            models: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"],
            keyURL: "https://platform.openai.com/api-keys",
            keyPlaceholder: "sk-…"
        ),
        AIProviderPreset(
            id: "deepseek", name: "DeepSeek", shortName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            defaultModel: "deepseek-chat",
            models: ["deepseek-chat", "deepseek-reasoner"],
            keyURL: "https://platform.deepseek.com/api_keys",
            keyPlaceholder: "sk-…"
        ),
        AIProviderPreset(
            id: "groq", name: "Groq", shortName: "Groq",
            baseURL: "https://api.groq.com/openai/v1",
            defaultModel: "llama-3.3-70b-versatile",
            models: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "openai/gpt-oss-120b"],
            keyURL: "https://console.groq.com/keys",
            keyPlaceholder: "gsk_…"
        ),
        AIProviderPreset(
            id: "openrouter", name: "OpenRouter", shortName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openai/gpt-4o-mini",
            models: ["openai/gpt-4o-mini", "openai/gpt-4o", "anthropic/claude-3.5-sonnet", "deepseek/deepseek-chat"],
            keyURL: "https://openrouter.ai/keys",
            keyPlaceholder: "sk-or-…"
        ),
        AIProviderPreset(
            id: "together", name: "Together AI", shortName: "Together",
            baseURL: "https://api.together.xyz/v1",
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            models: ["meta-llama/Llama-3.3-70B-Instruct-Turbo", "Qwen/Qwen2.5-72B-Instruct-Turbo"],
            keyURL: "https://api.together.xyz/settings/api-keys",
            keyPlaceholder: "…"
        ),
        custom
    ]

    static func normalize(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func match(baseURL: String) -> AIProviderPreset? {
        let norm = normalize(baseURL)
        guard !norm.isEmpty else { return nil }
        return all.first(where: { $0.id != "custom" && normalize($0.baseURL) == norm })
    }

    static func best(for baseURL: String) -> AIProviderPreset {
        match(baseURL: baseURL) ?? .custom
    }
}

// MARK: - AIConfig helpers

extension AIConfig {
    var primaryPreset: AIProviderPreset { AIProviderPreset.best(for: trimmedBaseURL) }
    var fallbackPreset: AIProviderPreset { AIProviderPreset.best(for: fallbackTrimmedBaseURL) }

    func applyPrimaryPreset(_ preset: AIProviderPreset) {
        guard preset.id != AIProviderPreset.custom.id else {
            // Clear so the provider stays "Custom" instead of snapping back to
            // whatever the previous URL matched.
            baseURLString = ""
            modelName = ""
            return
        }
        baseURLString = preset.baseURL
        modelName = preset.defaultModel
    }

    func applyFallbackPreset(_ preset: AIProviderPreset) {
        guard preset.id != AIProviderPreset.custom.id else {
            fallbackBaseURLString = ""
            fallbackModelName = ""
            return
        }
        fallbackBaseURLString = preset.baseURL
        fallbackModelName = preset.defaultModel
    }
}

// MARK: - Reusable editor

/// Provider chips + endpoint + model + API key.
/// `compact` renders a dark, tighter variant for the notch overlay.
struct AIProviderEditor: View {
    let title: String
    let icon: String
    var tint: Color = .blue

    @Binding var baseURL: String
    @Binding var model: String
    @Binding var apiKey: String
    var selectedPreset: AIProviderPreset
    var onSelectPreset: (AIProviderPreset) -> Void

    var compact: Bool = false
    var disabled: Bool = false
    var pageLabelWidth: CGFloat = 130

    @State private var showKey = false

    private var labelColor: Color { compact ? .white.opacity(0.72) : .secondary }
    private var valueColor: Color { compact ? .white : .primary }
    private var subtleColor: Color { compact ? .white.opacity(0.5) : .secondary }
    private var fieldFont: Font { .system(size: compact ? 10 : 11, design: .monospaced) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            header
            providerPicker
            rows
        }
        .opacity(disabled ? 0.55 : 1)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: compact ? 10 : 12, weight: .semibold, design: .rounded))
                .foregroundStyle(compact ? .white : .primary)
            Spacer(minLength: 4)
        }
    }

    /// Native segmented control — the macOS-standard way to pick one option from
    /// a small set. No custom borders; it follows system appearance, focus rings
    /// and accessibility automatically.
    private var providerPicker: some View {
        Picker("", selection: providerBinding) {
            ForEach(AIProviderPreset.all) { preset in
                Text(preset.shortName).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(compact ? .small : .regular)
        .disabled(disabled)
    }

    private var providerBinding: Binding<AIProviderPreset> {
        Binding(
            get: { selectedPreset },
            set: { onSelectPreset($0) }
        )
    }

    private var endpointPlaceholder: String {
        selectedPreset.id == AIProviderPreset.custom.id
            ? "https://your-endpoint/v1"
            : selectedPreset.baseURL
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            labeled("Endpoint") {
                TextField(endpointPlaceholder, text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(fieldFont)
                    .foregroundStyle(valueColor)
                    .disabled(disabled)
            }

            labeled("Model") {
                HStack(spacing: 6) {
                    TextField(selectedPreset.defaultModel.isEmpty ? "model-id" : selectedPreset.defaultModel, text: $model)
                        .textFieldStyle(.roundedBorder)
                        .font(fieldFont)
                        .foregroundStyle(valueColor)
                        .disabled(disabled)
                    if !selectedPreset.models.isEmpty {
                        Menu {
                            ForEach(selectedPreset.models, id: \.self) { m in
                                Button(m) { model = m }
                            }
                        } label: {
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(disabled)
                    }
                }
            }

            labeled("API Key") {
                HStack(spacing: 6) {
                    Group {
                        if showKey {
                            TextField(selectedPreset.keyPlaceholder, text: $apiKey)
                        } else {
                            SecureField(selectedPreset.keyPlaceholder, text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(fieldFont)
                    .foregroundStyle(valueColor)
                    .disabled(disabled)

                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                        .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
                        .buttonStyle(.plain)
                        .foregroundStyle(subtleColor)
                        .frame(width: compact ? 32 : 38)

                    if !selectedPreset.keyURL.isEmpty, let url = URL(string: selectedPreset.keyURL) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(subtleColor)
                        .help("Get a \(selectedPreset.shortName) API key")
                        .disabled(disabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: compact ? 9.5 : 11, weight: .medium, design: .rounded))
                .foregroundStyle(labelColor)
                .frame(width: compact ? 58 : pageLabelWidth, alignment: .leading)
            content()
        }
    }
}
