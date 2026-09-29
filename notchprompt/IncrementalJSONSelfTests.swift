//
//  IncrementalJSONSelfTests.swift
//
//  Coverage for reading a string field out of partial JSON. Escaped quotes are
//  the classic failure here: `{"answer":"say \"hi\""}` must not terminate the
//  field at the escaped quote.
//

import Foundation

enum IncrementalJSONSelfTests {
    static func run() {
        assertReadsCompleteField()
        assertReturnsNilBeforeKeyArrives()
        assertGrowsAsStreamArrives()
        assertEscapedQuoteDoesNotTerminateField()
        assertHandlesEscapes()
        assertHandlesUnicodeEscapes()
        assertToleratesFragmentCutMidEscape()
        assertIgnoresKeyInsideAnotherValue()
        assertHandlesWhitespaceAroundColon()
        assertSecondFieldCanBeReadIndependently()
    }

    private static func assertReadsCompleteField() {
        let read = IncrementalJSONStringField.read("answer", from: "{\"answer\":\"Fifty a seat\"}")
        assert(read != nil, "Should find the field")
        assert(read?.value == "Fifty a seat", "Unexpected value: \(read?.value ?? "nil")")
        assert(read?.isComplete == true, "Should be marked complete")
    }

    private static func assertReturnsNilBeforeKeyArrives() {
        assert(IncrementalJSONStringField.read("answer", from: "") == nil, "Empty text should yield nil")
        assert(
            IncrementalJSONStringField.read("answer", from: "{\"script_q") == nil,
            "Partial key should yield nil"
        )
    }

    private static func assertGrowsAsStreamArrives() {
        let chunks = [
            "{\"answer\":\"Tell ",
            "{\"answer\":\"Tell them ",
            "{\"answer\":\"Tell them it is fifty",
            "{\"answer\":\"Tell them it is fifty a seat"
        ]
        var previousLength = 0
        for chunk in chunks {
            guard let read = IncrementalJSONStringField.read("answer", from: chunk) else {
                assert(false, "Field should be readable from chunk: \(chunk)")
                return
            }
            assert(read.value.count >= previousLength, "Value should never shrink: \(read.value)")
            previousLength = read.value.count
            assert(read.isComplete == false, "Nothing is complete yet")
        }
    }

    private static func assertEscapedQuoteDoesNotTerminateField() {
        let read = IncrementalJSONStringField.read(
            "answer",
            from: "{\"answer\":\"say \\\"hello\\\" loudly\"}"
        )
        assert(read?.value == "say \"hello\" loudly", "Escaped quotes should survive, got: \(read?.value ?? "nil")")
        assert(read?.isComplete == true, "Should be complete")
    }

    private static func assertHandlesEscapes() {
        let read = IncrementalJSONStringField.read(
            "answer",
            from: "{\"answer\":\"line one\\nline two\\ttabbed\\\\slash\"}"
        )
        assert(
            read?.value == "line one\nline two\ttabbed\\slash",
            "Escapes should decode, got: \(read?.value ?? "nil")"
        )
    }

    private static func assertHandlesUnicodeEscapes() {
        let read = IncrementalJSONStringField.read("answer", from: "{\"answer\":\"caf\\u00e9\"}")
        assert(read?.value == "caf\u{e9}", "Unicode escape should decode, got: \(read?.value ?? "nil")")
    }

    private static func assertToleratesFragmentCutMidEscape() {
        // The stream was cut right after a backslash.
        let read = IncrementalJSONStringField.read("answer", from: "{\"answer\":\"fifty a seat\\")
        assert(read != nil, "Should still return a usable value")
        assert(read?.value == "fifty a seat", "Trailing backslash should be dropped, got: \(read?.value ?? "nil")")
        assert(read?.isComplete == false, "A cut escape is not completion")
    }

    private static func assertIgnoresKeyInsideAnotherValue() {
        // A stray "answer" inside the script_quote value must not be picked up.
        let text = "{\"script_quote\":\"the word \\\"answer\\\" appears here\",\"answer\":\"Real answer\"}"
        let read = IncrementalJSONStringField.read("answer", from: text)
        assert(read?.value == "Real answer", "Should find the real field, got: \(read?.value ?? "nil")")
    }

    private static func assertHandlesWhitespaceAroundColon() {
        let read = IncrementalJSONStringField.read("answer", from: "{\n  \"answer\"  :  \"Yes, absolutely\" \n}")
        assert(read?.value == "Yes, absolutely", "Whitespace should be tolerated, got: \(read?.value ?? "nil")")
    }

    private static func assertSecondFieldCanBeReadIndependently() {
        let text = "{\"answer\":\"Fifty a seat\",\"script_quote\":\"SECTION 3 pricing\"}"
        let answer = IncrementalJSONStringField.read("answer", from: text)
        let quote = IncrementalJSONStringField.read("script_quote", from: text)
        assert(answer?.value == "Fifty a seat", "Answer field wrong: \(answer?.value ?? "nil")")
        assert(quote?.value == "SECTION 3 pricing", "Quote field wrong: \(quote?.value ?? "nil")")
    }
}
