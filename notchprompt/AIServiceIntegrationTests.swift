//
//  AIServiceIntegrationTests.swift
//  notchprompt
//
//  End-to-end coverage of the real request path against a protocol-accurate
//  mock provider (scripts/mock_ai_provider.py).
//
//  Why this exists: every other test in this project exercises isolated logic.
//  Nothing had ever put a real HTTP request through AIService, so streaming,
//  JSON mode, the ignore-stream fallback, the response_format retry, and the
//  provider fallback chain were all unverified against anything resembling a
//  real provider.
//
//  Run with: scripts/run_ai_integration.sh
//

import Foundation
import Combine
import CoreGraphics

enum AIServiceIntegrationTests {
    private static var failures: [String] = []
    private static var checks = 0

    /// Returns true when every check passed, so a harness can exit accordingly.
    @discardableResult
    static func run(baseURL: String) async -> Bool {
        await testStreamedPlainAnswer(baseURL: baseURL)
        await testStructuredAnswerYieldsQuote(baseURL: baseURL)
        await testProviderIgnoringStreamIsHandled(baseURL: baseURL)
        await testResponseFormatRejectedIsRetried(baseURL: baseURL)
        await testFallbackProviderIsUsed(baseURL: baseURL)
        await testNoProviderAvailableThrows(baseURL: baseURL)
        await testCacheHitRestoresItsOwnQuote(baseURL: baseURL)
        await testAnswerWithoutQuoteClearsTheStaleOne(baseURL: baseURL)
        await testNonStreamingStructuredAnswerWorks(baseURL: baseURL)
        await testBareStructuredObjectIsAccepted(baseURL: baseURL)

        print("")
        if failures.isEmpty {
            print("ALL \(checks) AI INTEGRATION CHECKS PASSED")
            return true
        }
        print("\(failures.count) of \(checks) AI INTEGRATION CHECKS FAILED:")
        for failure in failures { print("  ✗ \(failure)") }
        return false
    }

    // MARK: - Assertions

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    // MARK: - Helpers

    @MainActor
    private static func configure(
        primaryPath: String,
        model: String = "mock-model",
        fallbackPath: String? = nil,
        fallbackModel: String = "mock-model",
        cache: Bool = false
    ) {
        let config = AIConfig.shared
        config.baseURLString = primaryPath
        config.modelName = model
        config.apiKey = "sk-test-key"
        config.answerCacheEnabled = cache
        config.includeScriptAsContext = false
        config.positionAwareContext = false
        config.fallbackEnabled = fallbackPath != nil
        if let fallbackPath {
            config.fallbackBaseURLString = fallbackPath
            config.fallbackModelName = fallbackModel
            config.fallbackApiKey = "sk-fallback-key"
        }
    }

    // MARK: - Tests

    @MainActor
    private static func testStreamedPlainAnswer(baseURL: String) async {
        configure(primaryPath: baseURL)
        AIConfig.shared.answerCacheEnabled = false

        var deltas: [String] = []
        let answer = try? await AIService.shared.answer(
            question: "How should I handle pricing?",
            scriptContext: nil,
            onDelta: { deltas.append($0) }
        )

        expect(answer != nil, "Streamed request should return an answer")
        expect(
            answer?.contains("annual pricing") == true,
            "Streamed answer should contain the text, got: \(answer ?? "nil")"
        )
        expect(deltas.count >= 4, "Should arrive in multiple deltas, got \(deltas.count)")
        expect(
            deltas.last == answer,
            "The final delta should equal the returned answer"
        )
        // The key streaming property: monotonically growing prefixes.
        var previousLength = 0
        var monotonic = true
        for delta in deltas {
            if delta.count < previousLength { monotonic = false }
            previousLength = delta.count
        }
        expect(monotonic, "Streamed deltas should never shrink")
    }

    @MainActor
    private static func testStructuredAnswerYieldsQuote(baseURL: String) async {
        configure(primaryPath: baseURL)
        AIConfig.shared.answerCacheEnabled = false

        var deltas: [String] = []
        let answer = try? await AIService.shared.answer(
            question: "What about the objection on pricing?",
            scriptContext: nil,
            onDelta: { deltas.append($0) },
            wantsScriptQuote: true
        )

        expect(answer != nil, "Structured request should return an answer")
        expect(
            answer?.contains("annual pricing") == true,
            "Answer should be extracted from the JSON, got: \(answer ?? "nil")"
        )
        // Critically, the user must never see raw JSON.
        let leakedJSON = (answer?.contains("{") == true) || deltas.contains { $0.contains("{\"") }
        expect(!leakedJSON, "Raw JSON must never be shown to the user")
        expect(
            AIService.shared.lastScriptQuote?.contains("objection number 27") == true,
            "Quote should be captured, got: \(AIService.shared.lastScriptQuote ?? "nil")"
        )
        expect(deltas.count > 1, "Structured answers should still stream, got \(deltas.count) deltas")
    }

    @MainActor
    private static func testProviderIgnoringStreamIsHandled(baseURL: String) async {
        // This provider ignores stream:true and returns a normal body.
        configure(primaryPath: baseURL.replacingOccurrences(of: "/v1", with: "/nostream/v1"))
        AIConfig.shared.answerCacheEnabled = false

        var deltas: [String] = []
        let answer = try? await AIService.shared.answer(
            question: "Pricing again?",
            scriptContext: nil,
            onDelta: { deltas.append($0) }
        )
        expect(answer != nil, "A non-streaming provider should still produce an answer")
        expect(
            answer?.contains("annual pricing") == true,
            "Ignore-stream body should be parsed, got: \(answer ?? "nil")"
        )
        expect(!deltas.isEmpty, "The user should still see the answer, got no deltas")
    }

    @MainActor
    private static func testResponseFormatRejectedIsRetried(baseURL: String) async {
        // This provider 400s on response_format, which should trigger one retry
        // without the parameter rather than failing the answer.
        configure(primaryPath: baseURL.replacingOccurrences(of: "/v1", with: "/nojson/v1"))
        AIConfig.shared.answerCacheEnabled = false

        let answer = try? await AIService.shared.answer(
            question: "Pricing with a picky provider?",
            scriptContext: nil,
            wantsScriptQuote: true
        )
        expect(answer != nil, "A provider rejecting response_format should not fail the answer")
        expect(
            answer?.contains("annual pricing") == true,
            "Retry without JSON mode should still return the answer, got: \(answer ?? "nil")"
        )
    }

    @MainActor
    private static func testFallbackProviderIsUsed(baseURL: String) async {
        // Primary is down; the fallback should carry the answer.
        configure(
            primaryPath: baseURL.replacingOccurrences(of: "/v1", with: "/flaky/v1"),
            fallbackPath: baseURL
        )
        AIConfig.shared.answerCacheEnabled = false

        let answer = try? await AIService.shared.answer(
            question: "Does the fallback work?",
            scriptContext: nil
        )
        expect(answer != nil, "Fallback provider should produce an answer")
        expect(
            answer?.contains("annual pricing") == true,
            "Fallback answer should come through, got: \(answer ?? "nil")"
        )
        expect(
            AIService.shared.lastSuccessfulProvider != nil,
            "The answering provider should be recorded"
        )
    }

    @MainActor
    private static func testNoProviderAvailableThrows(baseURL: String) async {
        // Both down, and no key configured: must surface an error rather than
        // hanging or returning an empty answer.
        configure(primaryPath: baseURL.replacingOccurrences(of: "/v1", with: "/flaky/v1"))
        AIConfig.shared.answerCacheEnabled = false
        AIConfig.shared.fallbackEnabled = false

        let answer = try? await AIService.shared.answer(
            question: "Anyone there?",
            scriptContext: nil
        )
        expect(answer == nil, "With every provider failing, the call should throw")
    }

    // MARK: - Quote lifecycle (regression)

    /// Regression: the quote was never cleared or cached, so a cache hit replayed
    /// the *previous* answer's quote and Jump sent the speaker to the wrong line.
    @MainActor
    private static func testCacheHitRestoresItsOwnQuote(baseURL: String) async {
        AnswerCache.shared.clear()
        configure(primaryPath: baseURL)
        AIConfig.shared.answerCacheEnabled = true

        // First, a real request, which stores an entry with a quote.
        do {
            _ = try await AIService.shared.answer(
                question: "How much is the annual plan?",
                scriptContext: nil,
                wantsScriptQuote: true
            )
        } catch {
            expect(false, "The first answer should succeed, threw: \(error)")
        }

        let original = AIService.shared.lastScriptQuote
        expect(
            original?.contains("objection number 27") == true,
            "Precondition: the first answer should carry a quote, got \(String(describing: original))"
        )

        // Overwrite the stored quote with a distinctly different one. The
        // next call is a cache hit, so the quote it reports must come from the
        // entry. Before the fix, `lastScriptQuote` was never touched on a cache
        // hit and simply kept whatever the previous request had left there.
        AnswerCache.shared.store(
            question: "How much is the annual plan?",
            answer: "Fifty a seat per month.",
            provider: "DeepSeek",
            model: "mock-model",
            quote: "a different quote that only exists in the cache entry"
        )
        let cached = try? await AIService.shared.answer(
            question: "How much is the annual plan?",
            scriptContext: nil,
            wantsScriptQuote: true
        )
        expect(
            AIService.shared.lastAnswerWasCached,
            "Precondition: the second call should be a cache hit"
        )
        expect(cached != nil, "A cache hit should still return the answer")
        expect(
            AIService.shared.lastScriptQuote == "a different quote that only exists in the cache entry",
            "A cache hit must take its quote from the entry, got \(String(describing: AIService.shared.lastScriptQuote))"
        )
        expect(
            AIService.shared.lastScriptQuote != original,
            "A cache hit must not keep the previous answer's quote"
        )
    }

    /// Regression: a provider that returns no quote must clear the previous one
    /// rather than leaving a Jump button pointing at unrelated text.
    @MainActor
    private static func testAnswerWithoutQuoteClearsTheStaleOne(baseURL: String) async {
        AnswerCache.shared.clear()
        configure(primaryPath: baseURL)
        AIConfig.shared.answerCacheEnabled = false

        _ = try? await AIService.shared.answer(
            question: "Tell me about the objection handling",
            scriptContext: nil,
            wantsScriptQuote: true
        )
        expect(
            AIService.shared.lastScriptQuote != nil,
            "Precondition: the structured answer should have a quote"
        )

        // Now ask without wanting a quote. Nothing should linger.
        _ = try? await AIService.shared.answer(
            question: "Who is on your team?",
            scriptContext: nil,
            wantsScriptQuote: false
        )
        expect(
            AIService.shared.lastScriptQuote == nil,
            "An answer with no quote must clear the previous one, got \(String(describing: AIService.shared.lastScriptQuote))"
        )
    }

    /// Regression: the non-streaming path decoded every response as a chat
    /// completion. With `response_format: json_object` that still works, but a
    /// structured answer fetched without `onDelta` — which is exactly what
    /// happens when a user turns streaming off with a script loaded — failed
    /// outright with `Empty choices` whenever the provider returned the object
    /// without the envelope.
    @MainActor
    private static func testNonStreamingStructuredAnswerWorks(baseURL: String) async {
        configure(primaryPath: baseURL.replacingOccurrences(of: "/v1", with: "/nostream/v1"))
        AIConfig.shared.answerCacheEnabled = false

        // No onDelta: this takes the non-streaming path.
        var answer: String?
        do {
            answer = try await AIService.shared.answer(
                question: "What is the annual plan cost?",
                scriptContext: nil,
                wantsScriptQuote: true
            )
        } catch {
            expect(false, "Non-streaming structured answer threw: \(error)")
        }
        expect(
            answer?.contains("annual pricing") == true,
            "The non-streaming structured answer should be extracted, got \(String(describing: answer))"
        )
        expect(
            AIService.shared.lastScriptQuote?.contains("objection number 27") == true,
            "The quote should be captured on the non-streaming path too, got \(String(describing: AIService.shared.lastScriptQuote))"
        )
    }

    /// Self-hosted OpenAI-compatible servers often return the structured object
    /// at the top level. That must not surface as `Empty choices`.
    @MainActor
    private static func testBareStructuredObjectIsAccepted(baseURL: String) async {
        configure(primaryPath: baseURL.replacingOccurrences(of: "/v1", with: "/bare/nostream/v1"))
        AIConfig.shared.answerCacheEnabled = false

        var answer: String?
        do {
            answer = try await AIService.shared.answer(
                question: "And what is in the pilot?",
                scriptContext: nil,
                wantsScriptQuote: true
            )
        } catch {
            expect(false, "A bare structured object should be accepted, threw: \(error)")
        }
        expect(
            answer?.contains("annual pricing") == true,
            "A bare structured object should still yield the answer, got \(String(describing: answer))"
        )
        expect(
            AIService.shared.lastScriptQuote?.contains("objection number 27") == true,
            "A bare structured object should still yield a quote, got \(String(describing: AIService.shared.lastScriptQuote))"
        )
    }
}
