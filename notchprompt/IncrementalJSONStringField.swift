//
//  IncrementalJSONStringField.swift
//  notchprompt
//
//  Reads one string field out of a JSON object that is still arriving.
//
//  Why this exists: jump-to-line needs the model to return
//  `{answer, script_quote}`, which means streaming raw JSON instead of prose.
//  Showing nothing until the stream ends would throw away the latency win from
//  Phase 1, so instead we read the `answer` field out of the partial JSON as
//  it lands and render that.
//
//  The accumulator is deliberately tiny: a few hundred characters, re-parsed per
//  delta. That is cheap and far easier to get right than incremental state.
//

import Foundation

enum IncrementalJSONStringField {
    struct Read {
        /// The decoded value so far.
        let value: String
        /// True once the closing quote has been seen.
        let isComplete: Bool
    }

    /// Read `key` out of the partial JSON in `text`.
    /// Returns nil until the key has been seen at all.
    static func read(_ key: String, from text: String) -> Read? {
        let chars = Array(text)
        let needle = Array("\"\(key)\"")

        guard let keyStart = indexOf(needle, in: chars) else { return nil }
        var i = keyStart + needle.count

        guard let colon = skipWhitespace(chars, from: i) else { return nil }
        guard colon < chars.count, chars[colon] == ":" else { return nil }
        i = colon + 1

        guard let quote = skipWhitespace(chars, from: i) else { return nil }
        guard quote < chars.count, chars[quote] == "\"" else { return nil }
        i = quote + 1

        var raw = ""
        var isComplete = false

        while i < chars.count {
            let character = chars[i]
            if character == "\\" {
                // An escape needs its follower; a trailing backslash is a
                // partial and must not corrupt the output.
                guard i + 1 < chars.count else { break }
                raw.append(character)
                raw.append(chars[i + 1])
                i += 2
                continue
            }
            if character == "\"" {
                isComplete = true
                break
            }
            raw.append(character)
            i += 1
        }

        return Read(value: decode(raw), isComplete: isComplete)
    }

    // MARK: - Helpers

    private static func indexOf(_ needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        var start = 0
        while start <= limit {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
            start += 1
        }
        return nil
    }

    private static func skipWhitespace(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            let character = chars[i]
            if character == " " || character == "\n" || character == "\t" || character == "\r" {
                i += 1
            } else {
                return i
            }
        }
        return nil
    }

    /// Decode JSON string escapes, tolerating a fragment cut mid-escape.
    static func decode(_ raw: String) -> String {
        var out = ""
        var iterator = Array(raw).makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\\" else {
                out.append(character)
                continue
            }
            guard let escape = iterator.next() else {
                // Trailing lone backslash: the rest has not arrived yet.
                break
            }
            switch escape {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{C}")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "u":
                var hex = ""
                for _ in 0..<4 {
                    if let digit = iterator.next() { hex.append(digit) } else { break }
                }
                if hex.count == 4, let code = UInt32(hex, radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                } else {
                    out.append("\u{FFFD}")
                }
            default:
                out.append(escape)
            }
        }
        return out
    }
}
