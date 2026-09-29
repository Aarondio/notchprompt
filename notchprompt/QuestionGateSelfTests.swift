//
//  QuestionGateSelfTests.swift
//  notchprompt
//
//  Checks for the question gate. These encode the trade-off explicitly:
//  suppressing a real question is expensive, sending small talk is cheap.
//

import Foundation

enum QuestionGateSelfTests {
    static func run() {
        assertQuestionMarkAlwaysSends()
        assertInterrogativeOpenersSend()
        assertContractionsAreRecognised()
        assertContractionPrefixDoesNotOvermatch()
        assertLongUtterancesSend()
        assertSentencePeriodDoesNotForceSend()
        assertSmallTalkIsSuppressed()
        assertThresholdIsHonoured()
        assertEmptyAndPunctuationOnlySuppress()
        assertCasingAndWhitespaceIgnored()
        assertTypicalSalesQuestionsSend()
    }

    private static func assertQuestionMarkAlwaysSends() {
        let gate = QuestionGate()
        assert(gate.decision(for: "how much?") == .send, "A trailing ? must always send")
        assert(gate.decision(for: "is that included?") == .send, "A trailing ? must always send")
        // Short but punctuated like a question.
        assert(gate.decision(for: "and?") == .send, "Even a one-word question mark should send")
    }

    private static func assertInterrogativeOpenersSend() {
        let gate = QuestionGate()
        let senders = [
            "what is your pricing",
            "why is that",
            "how do you handle it",
            "when can we start",
            "where do you deploy",
            "who owns that",
            "which plan includes it",
            "do you have startup pricing",
            "does it support sso",
            "did you build that in house",
            "can you send me the deck",
            "could we talk to engineering",
            "will you sign a data agreement",
            "would you discount for annual",
            "should we worry about latency",
            "is there a free tier",
            "are there seats included",
            "tell me about your security posture",
            "give me an example",
            "explain how billing works",
            "describe the onboarding",
            "walk me through the rollout"
        ]
        for phrase in senders {
            assert(gate.decision(for: phrase) == .send, "Expected send for: \"\(phrase)\"")
        }
    }

    private static func assertContractionsAreRecognised() {
        let gate = QuestionGate()
        // Each of these is short, so only contraction handling can save it.
        let senders = [
            "what's your budget",
            "don't you handle this",
            "aren't you the vendor",
            "isn't there a discount",
            "can't you do that",
            "won't you sign",
            "hasn't anyone asked"
        ]
        for phrase in senders {
            assert(gate.decision(for: phrase) == .send, "Expected send for: \"\(phrase)\"")
        }
    }

    private static func assertContractionPrefixDoesNotOvermatch() {
        // These must NOT be treated as interrogatives, otherwise prefix matching
        // on contractions would misfire on ordinary words.
        assert(!QuestionGate.isInterrogative("downtown"), "\"downtown\" must not match \"do\"")
        assert(!QuestionGate.isInterrogative("warehouse"), "\"warehouse\" must not match \"war\"")
        assert(!QuestionGate.isInterrogative("hometown"), "\"hometown\" must not match \"ho\"")
        // Proper nouns: an apostrophe plus a long tail must not match a stem.
        assert(!QuestionGate.isInterrogative("howard's"), "\"howard's\" must not match \"how\"")
        assert(!QuestionGate.isInterrogative("maya's"), "\"maya's\" must not match \"may\"")
        assert(!QuestionGate.isInterrogative("aaron's"), "\"aaron's\" must not match \"are\"")
        // Real contractions still work.
        assert(QuestionGate.isInterrogative("don't"), "\"don't\" must match \"do\"")
        assert(QuestionGate.isInterrogative("won't"), "\"won't\" must match \"will\" via the map")
        assert(QuestionGate.isInterrogative("shouldn't"), "\"shouldn't\" must match \"should\" via the map")
    }

    private static func assertLongUtterancesSend() {
        let gate = QuestionGate(minimumWords: 6)
        // No question words anywhere, but long enough to be worth answering.
        let long = "so the next step is onboarding and then we review at the end"
        assert(gate.decision(for: long) == .send, "Long utterances should send by default")

        // Short and free of any interrogative word.
        let short = "onboarding kicks off tomorrow"
        assert(gate.decision(for: short) == .suppress, "Short non-questions should suppress")
    }

    private static func assertSentencePeriodDoesNotForceSend() {
        // The recognizer runs with addsPunctuation = true, so most utterances
        // end in a period. Honouring that would send everything and make the
        // gate useless.
        let gate = QuestionGate()
        assert(gate.decision(for: "sounds good.") == .suppress, "A trailing period must not force a send")
        assert(gate.decision(for: "great thanks.") == .suppress, "A trailing period must not force a send")
        assert(gate.decision(for: "yeah.") == .suppress, "A trailing period must not force a send")
        // A question mark still wins, and interrogative words still send.
        assert(gate.decision(for: "how much.") == .send, "Interrogative words send despite the period")
    }

    private static func assertSmallTalkIsSuppressed() {
        let gate = QuestionGate()
        let filler = [
            "yeah",
            "totally",
            "sounds good",
            "right",
            "ok cool",
            "for sure",
            "let me pull that up",
            "one second",
            "yeah exactly",
            "great thanks"
        ]
        for phrase in filler {
            assert(gate.decision(for: phrase) == .suppress, "Expected suppress for: \"\(phrase)\"")
        }
    }

    private static func assertThresholdIsHonoured() {
        let strict = QuestionGate(minimumWords: 2)
        assert(strict.decision(for: "sounds good") == .send, "A low threshold should send short speech")

        let strictHigh = QuestionGate(minimumWords: 20)
        assert(
            strictHigh.decision(for: "what is the pricing model here") == .send,
            "Interrogatives should send regardless of threshold"
        )
        assert(
            strictHigh.decision(for: "one two three four five six seven") == .suppress,
            "A high threshold should suppress long non-questions"
        )
    }

    private static func assertEmptyAndPunctuationOnlySuppress() {
        let gate = QuestionGate()
        assert(gate.decision(for: "") == .suppress, "Empty input should suppress")
        assert(gate.decision(for: "   ") == .suppress, "Whitespace should suppress")
        assert(gate.decision(for: "...") == .suppress, "Punctuation only should suppress")
        assert(gate.decision(for: "uh um") == .suppress, "Filler only should suppress")
    }

    private static func assertCasingAndWhitespaceIgnored() {
        let gate = QuestionGate()
        assert(gate.decision(for: "  HOW MUCH IS IT  ") == .send, "Casing and padding should not matter")
        assert(gate.decision(for: "sounds   good") == .suppress, "Extra inner spacing should not matter")
    }

    private static func assertTypicalSalesQuestionsSend() {
        let gate = QuestionGate()
        // A representative sample of the utterances this feature exists for.
        let sales = [
            "so what happens if we exceed the seat limit",
            "we already use a competitor can you beat their pricing",
            "how does this handle our procurement process",
            "what is the implementation timeline looking like",
            "who would own this relationship on your side",
            "is there a not to exceed price for a three year deal",
            "can you do us a pilot with ten seats",
            "do you have references in the financial services space",
            "what security certifications do you hold",
            "tell me what happens to our data if we churn"
        ]
        for phrase in sales {
            assert(gate.decision(for: phrase) == .send, "Expected send for: \"\(phrase)\"")
        }
    }
}
