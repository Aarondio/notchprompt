//
//  AIService.swift
//  notchprompt
//
//  OpenAI-compatible chat service for answering background questions.
//  Brings your own API key & model. Supports OpenAI, Groq, OpenRouter, etc.
//

import Foundation
import Combine

enum AIServiceError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpError(Int, String)
    case decodingError(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing API key — tap the gear in the notch to pick a provider and paste its key."
        case .invalidURL: return "Invalid AI endpoint URL."
        case .httpError(let code, let body): return "AI request failed (\(code)): \(body.prefix(400))"
        case .decodingError(let s): return "AI response parse failed: \(s)"
        case .networkError(let s): return "Network error: \(s)"
        }
    }
}

struct AIChatMessage: Codable {
    let role: String // system | user | assistant
    let content: String
}

struct AIChatCompletionRequest: Codable {
    let model: String
    let messages: [AIChatMessage]
    let temperature: Double?
    let max_tokens: Int?
    let stream: Bool?

    init(model: String, messages: [AIChatMessage], temperature: Double = 0.7, maxTokens: Int = 600, stream: Bool = false) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.max_tokens = maxTokens
        self.stream = stream
    }
}

struct AIChatCompletionResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
            let reasoning_content: String? // DeepSeek R1
        }
        let message: Message?
        let text: String? // legacy completions fallback
    }
    let choices: [Choice]?
    let error: APIError?

    struct APIError: Codable {
        let message: String?
        let type: String?
        let code: String?
    }

    var firstText: String? {
        if let c = choices?.first?.message?.content, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return c
        }
        if let r = choices?.first?.message?.reasoning_content, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return r // fallback for DeepSeek reasoner when content is in reasoning field
        }
        return choices?.first?.text
    }
}

/// Stores AI config in UserDefaults + Keychain (API key).
/// For now API key lives in UserDefaults to keep it simple; can migrate to Keychain.
/// Supports primary provider + optional DeepSeek fallback.
final class AIConfig: ObservableObject {
    static let shared = AIConfig()

    @Published var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: Keys.baseURL) }
    }
    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: Keys.model) }
    }
    @Published var apiKey: String {
        didSet { Self.persistSecret(apiKey, account: Keys.apiKey) }
    }
    // — Fallback (DeepSeek) —
    @Published var fallbackEnabled: Bool {
        didSet { UserDefaults.standard.set(fallbackEnabled, forKey: Keys.fallbackEnabled) }
    }
    @Published var fallbackBaseURLString: String {
        didSet { UserDefaults.standard.set(fallbackBaseURLString, forKey: Keys.fallbackBaseURL) }
    }
    @Published var fallbackModelName: String {
        didSet { UserDefaults.standard.set(fallbackModelName, forKey: Keys.fallbackModel) }
    }
    @Published var fallbackApiKey: String {
        didSet { Self.persistSecret(fallbackApiKey, account: Keys.fallbackApiKey) }
    }

    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    /// Keep answer concise for notch display.
    @Published var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: Keys.maxTokens) }
    }
    @Published var includeScriptAsContext: Bool {
        didSet { UserDefaults.standard.set(includeScriptAsContext, forKey: Keys.includeScript) }
    }
    @Published var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: Keys.temperature) }
    }

    private enum Keys {
        static let baseURL = "aiBaseURL"
        static let model = "aiModel"
        static let apiKey = "aiApiKey"
        static let fallbackEnabled = "aiFallbackEnabled"
        static let fallbackBaseURL = "aiFallbackBaseURL"
        static let fallbackModel = "aiFallbackModel"
        static let fallbackApiKey = "aiFallbackApiKey"
        static let systemPrompt = "aiSystemPrompt"
        static let maxTokens = "aiMaxTokens"
        static let includeScript = "aiIncludeScript"
        static let temperature = "aiTemp"
    }

    private init() {
        let d = UserDefaults.standard
        self.baseURLString = d.string(forKey: Keys.baseURL) ?? "https://api.openai.com/v1"
        self.modelName = d.string(forKey: Keys.model) ?? "gpt-4o-mini"
        self.apiKey = Self.loadSecret(Keys.apiKey)
        self.fallbackEnabled = d.object(forKey: Keys.fallbackEnabled) as? Bool ?? false
        self.fallbackBaseURLString = d.string(forKey: Keys.fallbackBaseURL) ?? "https://api.deepseek.com"
        self.fallbackModelName = d.string(forKey: Keys.fallbackModel) ?? "deepseek-chat"
        self.fallbackApiKey = Self.loadSecret(Keys.fallbackApiKey)
        self.systemPrompt = d.string(forKey: Keys.systemPrompt) ?? AIConfig.defaultSystemPrompt
        self.maxTokens = d.object(forKey: Keys.maxTokens) as? Int ?? 320
        self.includeScriptAsContext = d.object(forKey: Keys.includeScript) as? Bool ?? true
        self.temperature = d.object(forKey: Keys.temperature) as? Double ?? 0.6
        // Backfill if empty
        if d.string(forKey: Keys.systemPrompt) == nil {
            UserDefaults.standard.set(systemPrompt, forKey: Keys.systemPrompt)
        }
    }

    // MARK: - Secret storage

    /// API keys live in the Keychain. Plaintext UserDefaults is only used as a
    /// fallback (and for one-time migration of older installs), then cleared.
    private static func loadSecret(_ account: String) -> String {
        if let keychainValue = KeychainStore.get(account), !keychainValue.isEmpty {
            // Migrate: drop any stale plaintext copy.
            UserDefaults.standard.removeObject(forKey: account)
            return keychainValue
        }

        let legacy = UserDefaults.standard.string(forKey: account) ?? ""
        if !legacy.isEmpty, KeychainStore.set(legacy, for: account) {
            UserDefaults.standard.removeObject(forKey: account)
        }
        return legacy
    }

    private static func persistSecret(_ value: String, account: String) {
        if KeychainStore.set(value, for: account) {
            UserDefaults.standard.removeObject(forKey: account)
        } else {
            UserDefaults.standard.set(value, forKey: account)
        }
    }

    static let defaultSystemPrompt = """
    You are a discreet interview assistant. The user is on a live call/meeting and a background question was just asked. \
    Provide a concise, confident answer the user can deliver verbally. \
    Rules: be brief (2-5 sentences or 1 short bullet list), no preamble, no "as an AI", prioritize accuracy. \
    If unsure, give best pragmatic answer and flag uncertainty in one short phrase. \
    Tailor tone to professional and helpful.
    """

    var trimmedBaseURL: String {
        var s = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow pasting full chat/completions URL — normalize it to base
        // e.g. https://api.deepseek.com/chat/completions -> https://api.deepseek.com
        // or https://api.deepseek.com/v1/chat/completions -> https://api.deepseek.com/v1
        if let range = s.range(of: "/chat/completions", options: .caseInsensitive) {
            s = String(s[..<range.lowerBound])
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "https://api.openai.com/v1" : s
    }

    var chatCompletionsURL: URL? {
        // Handles:
        // - https://api.openai.com/v1            -> .../v1/chat/completions
        // - https://api.deepseek.com             -> .../chat/completions
        // - https://api.deepseek.com/v1          -> .../v1/chat/completions (also valid for DeepSeek compat)
        // - https://api.groq.com/openai/v1       -> .../openai/v1/chat/completions
        URL(string: "\(trimmedBaseURL)/chat/completions")
    }

    /// Convenience: provider label for UI
    var providerLabel: String {
        let u = trimmedBaseURL.lowercased()
        if u.contains("deepseek") { return "DeepSeek" }
        if u.contains("groq") { return "Groq" }
        if u.contains("openrouter") { return "OpenRouter" }
        if u.contains("openai") { return "OpenAI" }
        return "Custom"
    }

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Fallback helpers

    var fallbackTrimmedBaseURL: String {
        var s = fallbackBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "/chat/completions", options: .caseInsensitive) {
            s = String(s[..<range.lowerBound])
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "https://api.deepseek.com" : s
    }

    var fallbackChatCompletionsURL: URL? {
        URL(string: "\(fallbackTrimmedBaseURL)/chat/completions")
    }

    var fallbackProviderLabel: String {
        let u = fallbackTrimmedBaseURL.lowercased()
        if u.contains("deepseek") { return "DeepSeek" }
        if u.contains("groq") { return "Groq" }
        if u.contains("openrouter") { return "OpenRouter" }
        if u.contains("openai") { return "OpenAI" }
        return "Custom"
    }

    var fallbackHasKey: Bool { !fallbackApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var fallbackIsUsable: Bool { fallbackEnabled && fallbackHasKey && fallbackChatCompletionsURL != nil }
}

@MainActor
final class AIService: ObservableObject {
    static let shared = AIService()

    @Published private(set) var lastSuccessfulProvider: String?
    private let config = AIConfig.shared
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Reasoning models (deepseek-reasoner, o-series) can be slow.
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Answer a background question. Tries primary provider, then falls back to DeepSeek if enabled.
    func answer(question: String, scriptContext: String? = nil) async throws -> String {
        let userContent: String = {
            var parts: [String] = []
            if config.includeScriptAsContext, let ctx = scriptContext?.trimmingCharacters(in: .whitespacesAndNewlines), !ctx.isEmpty {
                let truncated = String(ctx.prefix(6000))
                parts.append("Context (my script / notes):\n\"\"\"\n\(truncated)\n\"\"\"")
            }
            parts.append("Background question heard:\n\"\(question.trimmingCharacters(in: .whitespacesAndNewlines))\"")
            parts.append("Provide the best short spoken answer I can give right now.")
            return parts.joined(separator: "\n\n")
        }()

        let messages: [AIChatMessage] = [
            .init(role: "system", content: config.systemPrompt),
            .init(role: "user", content: userContent)
        ]

        // Build ordered provider attempts: primary always first, then fallback if usable
        struct Attempt {
            let label: String
            let url: URL?
            let model: String
            let apiKey: String
        }

        var attempts: [Attempt] = []
        attempts.append(Attempt(
            label: config.providerLabel,
            url: config.chatCompletionsURL,
            model: config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4o-mini" : config.modelName,
            apiKey: config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        if config.fallbackIsUsable {
            let fbModel = config.fallbackModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "deepseek-chat" : config.fallbackModelName
            attempts.append(Attempt(
                label: config.fallbackProviderLabel,
                url: config.fallbackChatCompletionsURL,
                model: fbModel,
                apiKey: config.fallbackApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        var lastError: Error?
        for (idx, a) in attempts.enumerated() {
            // Validate this attempt
            guard !a.apiKey.isEmpty else {
                lastError = AIServiceError.missingAPIKey
                // If primary missing key but we have a fallback, continue; otherwise fail fast if only one attempt
                if idx == attempts.count - 1 { // last attempt still missing key -> throw
                    throw AIServiceError.missingAPIKey
                }
                continue
            }
            guard let url = a.url else {
                lastError = AIServiceError.invalidURL
                continue
            }

            do {
                let text = try await performRequest(url: url, model: a.model, apiKey: a.apiKey, messages: messages)
                lastSuccessfulProvider = a.label
                return text
            } catch {
                lastError = error
                // Don't retry on client errors that are likely config mistakes unless we have a fallback
                let isLast = idx == attempts.count - 1
                if isLast { break }
                // For transient/server/network errors, fall through to the next provider.
#if DEBUG
                print("[AIService] Primary (\(a.label)) failed: \(error.localizedDescription) — trying fallback (\(attempts[idx + 1].label))…")
#endif
                continue
            }
        }

        // All attempts exhausted
        if let e = lastError { throw e }
        throw AIServiceError.networkError("No provider available")
    }

    private func performRequest(url: URL, model: String, apiKey: String, messages: [AIChatMessage]) async throws -> String {
        let reqBody = AIChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: config.temperature,
            maxTokens: config.maxTokens
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(reqBody)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIServiceError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AIServiceError.networkError("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIServiceError.httpError(http.statusCode, body)
        }
        do {
            let decoded = try JSONDecoder().decode(AIChatCompletionResponse.self, from: data)
            if let e = decoded.error?.message, !e.isEmpty {
                throw AIServiceError.httpError(http.statusCode, e)
            }
            guard let text = decoded.firstText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw AIServiceError.decodingError("Empty choices")
            }
            return text
        } catch let err as AIServiceError {
            throw err
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AIServiceError.decodingError("\(error.localizedDescription) — raw: \(raw.prefix(500))")
        }
    }

    /// Fire-and-forget streaming variant could be added later; polling first.

    // MARK: - Provider ping (isolated)

    func testPrimaryConnection() async throws -> String {
        guard config.hasKey, let url = config.chatCompletionsURL else { throw AIServiceError.missingAPIKey }
        let model = config.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-4o-mini" : config.modelName
        return try await performRequest(
            url: url, model: model, apiKey: config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [.init(role: "system", content: "You are a connectivity test."), .init(role: "user", content: "Say 'Notchprompt OK' in 5 words.")]
        )
    }

    func testFallbackConnection() async throws -> String {
        guard config.fallbackIsUsable, let url = config.fallbackChatCompletionsURL else { throw AIServiceError.missingAPIKey }
        let model = config.fallbackModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "deepseek-chat" : config.fallbackModelName
        return try await performRequest(
            url: url, model: model, apiKey: config.fallbackApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [.init(role: "system", content: "You are a connectivity test."), .init(role: "user", content: "Say 'Notchprompt OK' in 5 words.")]
        )
    }
}
