//
//  SSEStreamParser.swift
//  notchprompt
//
//  Incremental Server-Sent Events parser.
//
//  `URLSession.AsyncBytes` yields a stream of single bytes, so the parser
//  buffers partial lines and only emits complete events. This is deliberately
//  dependency-free and side-effect-free so it can be unit tested directly.
//

import Foundation

struct SSEStreamParser {
    struct Event: Equatable {
        /// The payload with the `data:` field name and one leading space removed.
        let data: String

        /// The OpenAI-compatible terminator.
        var isDone: Bool { data == "[DONE]" }
    }

    private var buffer = Data()

    /// Feed bytes in, get back every event that is now complete.
    mutating func append(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        return drainCompleteLines()
    }

    /// Emit any trailing content that never received a newline. Call once the
    /// underlying stream ends so a final event without a trailing newline is
    /// not lost.
    mutating func flush() -> [Event] {
        guard !buffer.isEmpty else { return [] }
        let remainder = buffer
        buffer = Data()
        return parse(line: String(decoding: remainder, as: UTF8.self))
    }

    // MARK: - Private

    private mutating func drainCompleteLines() -> [Event] {
        var events: [Event] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            events.append(contentsOf: parse(line: line))
        }
        return events
    }

    private func parse(line: String) -> [Event] {
        // Blank line: event separator, nothing to emit.
        guard !line.isEmpty else { return [] }
        // Comment / keep-alive heartbeat.
        if line.hasPrefix(":") { return [] }

        guard line.hasPrefix("data:") else { return [] }

        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        return [Event(data: payload)]
    }
}
