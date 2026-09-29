//
//  AIStructuredAnswerSelfTests.swift
//
//  Coverage for the tolerant `{answer, script_quote}` parser. Models wrap JSON
//  in fences, prepend prose, and occasionally truncate, so every one of those
//  has to degrade to a usable answer rather than an error.
//

import Foundation

enum AIStructuredAnswerSelfTests {
    static func run() {
        assertParsesCleanObject()
        assertAcceptsCamelCaseQuoteKey()
        assertStripsCodeFence()
        assertRecoversFromLeadingProse()
        assertRecoversFromTruncatedStream()
        assertRejectsPlainProse()
        assertRejectsEmptyAnswer()
        assertEmptyQuoteBecomesNil()
        assertWhitespaceIsTrimmedFromQuote()
    }

    private static func assertParsesCleanObject() {
        let raw = #"{"answer":"Fifty a seat, billed annually.","script_quote":"SECTION 3 pricing"}"#
        guard let parsed = AIStructuredAnswer.parse(raw) else {
            assert(false, "Clean JSON should parse")
            return
        }
        assert(parsed.answer == "Fifty a seat, billed annually.", "Answer wrong: \(parsed.answer)")
        assert(parsed.scriptQuote == "SECTION 3 pricing", "Quote wrong: \(parsed.scriptQuote ?? "nil")")
    }

    private static func assertAcceptsCamelCaseQuoteKey() {
        let raw = #"{"answer":"Yes.","scriptQuote":"objection number two"}"#
        let parsed = AIStructuredAnswer.parse(raw)
        assert(parsed?.scriptQuote == "objection number two", "camelCase key should be accepted")
    }

    private static func assertStripsCodeFence() {
        let raw = """
        ```json
        {"answer":"Noted.","script_quote":"closing section"}
        ```
        """
        let parsed = AIStructuredAnswer.parse(raw)
        assert(parsed?.answer == "Noted.", "Fenced JSON should parse, got: \(parsed?.answer ?? "nil")")
        assert(parsed?.scriptQuote == "closing section", "Quote should survive the fence")
    }

    private static func assertRecoversFromLeadingProse() {
        // Some models emit a sentence before the JSON.
        let raw = "Here you go: {\"answer\":\"Thirty days.\",\"script_quote\":\"trial terms\"}"
        let parsed = AIStructuredAnswer.parse(raw)
        assert(parsed?.answer == "Thirty days.", "Should recover past prose, got: \(parsed?.answer ?? "nil")")
    }

    private static func assertRecoversFromTruncatedStream() {
        // Stream cut off before the quote field finished.
        let raw = #"{"answer":"Standard annual billing with no setup fee","script_quote":"annual bill"#
        let parsed = AIStructuredAnswer.parse(raw)
        assert(parsed != nil, "A truncated stream should still yield the answer")
        assert(
            parsed?.answer == "Standard annual billing with no setup fee",
            "Answer should be complete, got: \(parsed?.answer ?? "nil")"
        )
    }

    private static func assertRejectsPlainProse() {
        assert(AIStructuredAnswer.parse("Fifty a seat, billed annually.") == nil, "Plain prose is not structured")
        assert(AIStructuredAnswer.parse("") == nil, "Empty text is not structured")
        assert(AIStructuredAnswer.parse("{\"other\":1}") == nil, "A JSON object without an answer is not usable")
    }

    private static func assertRejectsEmptyAnswer() {
        assert(AIStructuredAnswer.parse(#"{"answer":"   ","script_quote":"x"}"#) == nil, "A blank answer is not usable")
    }

    private static func assertEmptyQuoteBecomesNil() {
        let parsed = AIStructuredAnswer.parse(#"{"answer":"Fifty a seat.","script_quote":""}"#)
        assert(parsed?.answer == "Fifty a seat.", "Answer should still parse")
        assert(parsed?.scriptQuote == nil, "An empty quote should surface as nil, not empty string")
    }

    private static func assertWhitespaceIsTrimmedFromQuote() {
        let parsed = AIStructuredAnswer.parse(#"{"answer":"Yes.","script_quote":"  spaced out  "}"#)
        assert(parsed?.scriptQuote == "spaced out", "Quote should be trimmed, got: \(parsed?.scriptQuote ?? "nil")")
    }
}
