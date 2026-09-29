//
//  QuestionGate.swift
//  notchprompt
//
//  Cheap local pre-filter that decides whether a captured utterance is worth
//  an API call.
//
//  Design intent: PERMISSIVE. The goal is to skip small talk and filler — which
//  is where the money is wasted during a call — not to outsmart the speaker.
//  Anything this rejects can still be sent manually from the notch, so a false
//  negative costs one tap, never a lost question.
//

import Foundation

struct QuestionGate: Equatable {
    /// Utterances with at least this many words are sent even without a
    /// question mark or an interrogative opener.
    var minimumWords: Int = 6

    enum Decision: Equatable {
        case send
        case suppress
    }

    /// Words that signal a question when they open or appear in the utterance.
    /// Deliberately broad: a false positive costs a fraction of a cent, while a
    /// false negative costs the user their answer.
    private static let interrogativeStems: Set<String> = [
        "what", "why", "how", "when", "where", "who", "whom", "whose", "which",
        "is", "are", "was", "were", "am",
        "do", "does", "did",
        "can", "could", "will", "would", "should", "shall", "may", "might",
        "have", "has", "had",
        "any", "tell", "give", "explain", "describe", "walk", "suppose", "imagine"
    ]

    /// Contractions that do not reduce to a simple prefix of their stem
    /// ("won't" → "will" is not a prefix relationship).
    private static let contractionStems: [String: String] = [
        "whats": "what", "wheres": "where", "whos": "who", "hows": "how", "whys": "why",
        "dont": "do", "doesnt": "does", "didnt": "did", "cant": "can", "couldnt": "could",
        "wont": "will", "wouldnt": "would", "shouldnt": "should", "shant": "shall",
        "isnt": "is", "arent": "are", "wasnt": "was", "werent": "were", "aint": "is",
        "havent": "have", "hasnt": "has", "hadnt": "have", "mightnt": "might"
    ]

    func decision(for transcript: String) -> Decision {
        let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return .suppress }

        // A trailing '?' is unambiguous.
        //
        // Deliberately NOT treating '.' or '!' the same way: the recognizer runs
        // with `addsPunctuation = true`, so nearly every utterance ends in a
        // period. Honouring that would make the gate send everything and defeat
        // its whole purpose.
        if raw.hasSuffix("?") { return .send }

        let words = raw
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        guard !words.isEmpty else { return .suppress }

        if words.count >= minimumWords { return .send }
        if words.contains(where: Self.isInterrogative) { return .send }

        return .suppress
    }

    /// True when the word reads like a question opener.
    ///
    /// Contractions are resolved by their suffix, not by length heuristics:
    /// `"don't"` reduces to stem `do`, and `"what's"` to `what`. Matching on a
    /// length rule instead would be unreliable, because `"don't"` (do + "nt")
    /// and `"maya's"` (may + "as") are structurally identical — only the suffix
    /// distinguishes a real contraction from a proper noun. The explicit map
    /// covers the irregular forms where the suffix rule cannot help, such as
    /// "won't" → "will" and "ain't" → "is".
    static func isInterrogative(_ word: String) -> Bool {
        if interrogativeStems.contains(word) { return true }
        guard word.contains("'") else { return false }

        let collapsed = word.replacingOccurrences(of: "'", with: "")

        if let mapped = contractionStems[collapsed], interrogativeStems.contains(mapped) {
            return true
        }
        // "n't" contractions: don't -> do, isn't -> is, weren't -> were.
        if collapsed.hasSuffix("nt"), interrogativeStems.contains(String(collapsed.dropLast(2))) {
            return true
        }
        // "'s" contractions: what's -> what, who's -> who.
        if collapsed.hasSuffix("s"), interrogativeStems.contains(String(collapsed.dropLast(1))) {
            return true
        }
        return false
    }
}
