//
//  SSESelfTests.swift
//  notchprompt
//
//  Checks for the incremental Server-Sent Events parser used for streaming
//  chat completions. The parser is the piece most likely to break silently on
//  an edge case (a payload split across two network reads), so it is covered
//  directly rather than only through a live request.
//

import Foundation

enum SSESelfTests {
    static func run() {
        assertSingleEvent()
        assertMultipleEventsInOneChunk()
        assertEventSplitAcrossChunks()
        assertByteByByteDelivery()
        assertCarriageReturnsStripped()
        assertCommentsAndSeparatorsIgnored()
        assertDoneSentinelDetected()
        assertDataWithoutLeadingSpace()
        assertFlushEmitsTrailingLine()
        assertEmptyInputYieldsNothing()
        assertRealisticOpenAIChunkSequence()
    }

    // MARK: - Basics

    private static func assertSingleEvent() {
        var parser = SSEStreamParser()
        let events = parser.append(Data("data: {\"a\":1}\n".utf8))
        assert(events.count == 1, "Expected one event, got \(events.count)")
        assert(events.first?.data == "{\"a\":1}", "Unexpected payload: \(events.first?.data ?? "nil")")
    }

    private static func assertMultipleEventsInOneChunk() {
        var parser = SSEStreamParser()
        let payload = "data: one\n\ndata: two\n\ndata: [DONE]\n\n"
        let events = parser.append(Data(payload.utf8))
        assert(events.count == 3, "Expected three events, got \(events.count)")
        assert(events.map(\.data) == ["one", "two", "[DONE]"], "Unexpected payloads: \(events.map(\.data))")
    }

    private static func assertEventSplitAcrossChunks() {
        // The payload is deliberately cut mid-JSON, which is what happens when a
        // network read lands in the middle of a frame.
        var parser = SSEStreamParser()
        let first = parser.append(Data("data: {\"choi".utf8))
        assert(first.isEmpty, "A partial line must not emit an event")

        let second = parser.append(Data("ces\":[1]}\n".utf8))
        assert(second.count == 1, "Expected the completed line to emit one event, got \(second.count)")
        assert(second.first?.data == "{\"choices\":[1]}", "Unexpected payload: \(second.first?.data ?? "nil")")
    }

    private static func assertByteByByteDelivery() {
        // URLSession.AsyncBytes yields single bytes; the parser must buffer.
        var parser = SSEStreamParser()
        var collected: [String] = []
        for byte in Array("data: hello\n".utf8) {
            collected += parser.append(Data([byte])).map(\.data)
        }
        assert(collected == ["hello"], "Byte-by-byte delivery should still yield one event, got \(collected)")
    }

    private static func assertCarriageReturnsStripped() {
        var parser = SSEStreamParser()
        let events = parser.append(Data("data: windows\r\n".utf8))
        assert(events.first?.data == "windows", "CRLF should be stripped, got: \(events.first?.data ?? "nil")")
    }

    private static func assertCommentsAndSeparatorsIgnored() {
        var parser = SSEStreamParser()
        let payload = ": keep-alive\n\nevent: message\nid: 7\ndata: real\n\nretry: 100\n"
        let events = parser.append(Data(payload.utf8))
        assert(events.count == 1, "Only data lines should emit events, got \(events.count)")
        assert(events.first?.data == "real", "Unexpected payload: \(events.first?.data ?? "nil")")
    }

    private static func assertDoneSentinelDetected() {
        var parser = SSEStreamParser()
        let events = parser.append(Data("data: [DONE]\n".utf8))
        assert(events.count == 1, "Expected the terminator to be emitted")
        assert(events.first?.isDone == true, "[DONE] should be flagged as the terminator")

        var other = SSEStreamParser()
        let notDone = other.append(Data("data: [DONE] trailing\n".utf8))
        assert(notDone.first?.isDone == false, "Only an exact [DONE] is the terminator")
    }

    private static func assertDataWithoutLeadingSpace() {
        var parser = SSEStreamParser()
        let events = parser.append(Data("data:tight\n".utf8))
        assert(events.first?.data == "tight", "A missing space after data: should still parse")
    }

    private static func assertFlushEmitsTrailingLine() {
        var parser = SSEStreamParser()
        let events = parser.append(Data("data: no-newline-at-end".utf8))
        assert(events.isEmpty, "Without a newline the line is not yet complete")

        let flushed = parser.flush()
        assert(flushed.count == 1, "flush() should emit the trailing line")
        assert(flushed.first?.data == "no-newline-at-end", "Unexpected payload after flush")

        assert(parser.flush().isEmpty, "A second flush should be empty")
    }

    private static func assertEmptyInputYieldsNothing() {
        var parser = SSEStreamParser()
        assert(parser.append(Data()).isEmpty, "Empty input should emit nothing")
        assert(parser.flush().isEmpty, "Flushing an empty parser should emit nothing")
    }

    // MARK: - Realistic sequence

    private static func assertRealisticOpenAIChunkSequence() {
        let wire = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Tell "}}]}

        data: {"choices":[{"delta":{"content":"them you "}}]}

        data: {"choices":[{"delta":{"content":"charge twice."}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """

        var parser = SSEStreamParser()
        var bytes = Data(wire.utf8)

        // Feed in ragged chunks, the way a real socket delivers them.
        var content = ""
        var sawDone = false
        var cursor = 0
        for size in [7, 1, 40, 3, 512, 29] {
            guard cursor < bytes.count else { break }
            let end = min(cursor + size, bytes.count)
            for event in parser.append(bytes[cursor..<end]) {
                if event.isDone { sawDone = true; continue }
                guard let chunk = try? JSONDecoder().decode(AIStreamChunk.self, from: Data(event.data.utf8)) else {
                    continue
                }
                if let c = chunk.choices?.first?.delta?.content {
                    content += c
                }
            }
            cursor = end
        }
        bytes.removeAll()

        assert(sawDone, "The [DONE] terminator should be seen")
        assert(content == "Tell them you charge twice.", "Reassembled content was: \(content)")
    }
}
