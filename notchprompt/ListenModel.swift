//
//  ListenModel.swift
//  notchprompt
//
//  Orchestrates microphone capture + AI answer for background questions.
//  Used by the notch Listen button.
//

import Foundation
import AppKit
import Combine
import AVFoundation

enum ListenState: Equatable {
    case idle
    case requestingPermission
    case listening(transcript: String)
    case thinking(question: String)
    /// The gate decided this was probably not a question, so nothing was sent.
    /// The user can still force it through.
    case gateSuppressed(String)
    /// Answer is arriving token by token. `reasoning` is the model's internal
    /// reasoning (DeepSeek R1) and is never shown as the answer.
    case streaming(answer: String, reasoning: String)
    case answering(String)   // holds completed answer
    case error(String)
}

/// A past question and answer, kept so the speaker can recall something that
/// flashed by.
struct ListenHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let question: String
    let answer: String
    let provider: String?
    /// Verbatim script passage supporting the answer, when one came back.
    let quote: String?
    let wasCached: Bool
    let date: Date
}

@MainActor
final class ListenModel: ObservableObject {
    static let shared = ListenModel()

    @Published private(set) var state: ListenState = .idle
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastAnswer: String = ""
    @Published private(set) var lastQuestion: String = ""
    @Published private(set) var lastProvider: String?
    @Published private(set) var lastAnswerWasCached = false
    @Published private(set) var isListening = false

    /// Recent Q&A, newest first.
    @Published private(set) var history: [ListenHistoryEntry] = []

    /// Non-nil while the notch is showing a past answer instead of the latest.
    @Published var browsingIndex: Int?

    /// The entry currently being viewed: the browsed one, or nil if live.
    var browsedEntry: ListenHistoryEntry? {
        guard let index = browsingIndex, index >= 0, index < history.count else { return nil }
        return history[index]
    }

    /// What the answer card should show — browsed entry wins over the live one.
    var displayedEntry: ListenHistoryEntry? { browsedEntry }

    /// The supporting quote for whatever is on screen right now.
    var activeQuote: String? { browsedEntry?.quote ?? lastScriptQuote }

    /// Settings. All of these persist, so a language or tuning choice survives a
    /// relaunch instead of silently resetting.
    @Published var autoSendOnSilence: Bool {
        didSet {
            speech.autoSendOnSilence = autoSendOnSilence
            Defaults.set(autoSendOnSilence, .autoSend)
        }
    }
    @Published var continuousListening: Bool {
        didSet { Defaults.set(continuousListening, .continuous) }
    }
    @Published var showAnswerInNotch: Bool {
        didSet { Defaults.set(showAnswerInNotch, .showAnswerCard) }
    }
    /// Stream answers so the first words appear immediately. Turn off to force
    /// a single non-streamed response.
    @Published var streamAnswers: Bool {
        didSet { Defaults.set(streamAnswers, .streamAnswers) }
    }
    /// Skip small talk instead of spending a request on it.
    @Published var questionGateEnabled: Bool {
        didSet { Defaults.set(questionGateEnabled, .gateEnabled) }
    }
    /// Utterance length at or above which we send regardless of wording.
    @Published var questionGateMinWords: Int {
        didSet { Defaults.set(questionGateMinWords, .gateMinWords) }
    }
    /// How long a pause must be before an utterance is considered finished.
    @Published var silenceThreshold: TimeInterval {
        didSet {
            speech.silenceThreshold = silenceThreshold
            Defaults.set(silenceThreshold, .silenceThreshold)
        }
    }
    /// BCP-47 identifier for speech recognition. Empty means system default.
    @Published var speechLocaleIdentifier: String {
        didSet { Defaults.set(speechLocaleIdentifier, .speechLocale) }
    }

    private enum DefaultsKey: String {
        case autoSend = "listenAutoSend"
        case continuous = "listenContinuous"
        case showAnswerCard = "listenShowAnswerCard"
        case streamAnswers = "listenStreamAnswers"
        case gateEnabled = "listenGateEnabled"
        case gateMinWords = "listenGateMinWords"
        case silenceThreshold = "listenSilenceThreshold"
        case speechLocale = "listenSpeechLocale"
    }

    private enum Defaults {
        static let store = UserDefaults.standard
        static func set(_ value: Any, _ key: DefaultsKey) {
            store.set(value, forKey: key.rawValue)
        }
        static func bool(_ key: DefaultsKey, default fallback: Bool) -> Bool {
            store.object(forKey: key.rawValue) as? Bool ?? fallback
        }
        static func int(_ key: DefaultsKey, default fallback: Int) -> Int {
            store.object(forKey: key.rawValue) as? Int ?? fallback
        }
        static func double(_ key: DefaultsKey, default fallback: Double) -> Double {
            store.object(forKey: key.rawValue) as? Double ?? fallback
        }
        static func string(_ key: DefaultsKey, default fallback: String) -> String {
            store.string(forKey: key.rawValue) ?? fallback
        }
    }

    /// Notch-native AI provider/key setup panel.
    @Published var isAISetupVisible = false

    private let speech = SpeechRecognizerService()
    private let ai = AIService.shared
    private let prompter = PrompterModel.shared
    private let position = ScriptPositionModel.shared
    private let aiConfig = AIConfig.shared

    /// A verbatim quote from the script supporting the last answer, when the
    /// provider returned one. Enables "Jump to this line".
    @Published private(set) var lastScriptQuote: String?
    @Published private(set) var jumpFailed = false

    /// Latest accumulated reasoning text, kept out of the visible answer.
    private var currentReasoning: String = ""

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        _autoSendOnSilence = Published(initialValue: Defaults.bool(.autoSend, default: true))
        _continuousListening = Published(initialValue: Defaults.bool(.continuous, default: false))
        _showAnswerInNotch = Published(initialValue: Defaults.bool(.showAnswerCard, default: true))
        _streamAnswers = Published(initialValue: Defaults.bool(.streamAnswers, default: true))
        _questionGateEnabled = Published(initialValue: Defaults.bool(.gateEnabled, default: true))
        _questionGateMinWords = Published(initialValue: Defaults.int(.gateMinWords, default: 6))
        _silenceThreshold = Published(initialValue: Defaults.double(.silenceThreshold, default: 1.4))
        _speechLocaleIdentifier = Published(initialValue: Defaults.string(.speechLocale, default: ""))

        speech.autoSendOnSilence = autoSendOnSilence
        speech.silenceThreshold = silenceThreshold

        speech.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Mirror speech transcript into ListenState
        speech.$partialTranscript
            .receive(on: RunLoop.main)
            .sink { [weak self] partial in
                guard let self else { return }
                if self.isListening {
                    self.state = .listening(transcript: partial)
                }
            }
            .store(in: &cancellables)

        speech.$isListening
            .receive(on: RunLoop.main)
            .sink { [weak self] v in self?.isListening = v }
            .store(in: &cancellables)

        speech.onAutoPause = { [weak self] text in
            Task { @MainActor in
                guard let self, self.autoSendOnSilence, self.isListening else { return }
                // For background questions: auto-submit after silence.
                self.submitQuestion(text, auto: true)
            }
        }
    }

    // MARK: Permissions

    func ensurePermission() async -> Bool {
        if speech.isAuthorized {
            return true
        }
        state = .requestingPermission
        let ok = await speech.requestAuthorization()
        if !ok {
            state = .error("Microphone or Speech not authorized. Enable in System Settings → Privacy & Security.")
        } else {
            state = .idle
        }
        return ok
    }

    // MARK: Toggle

    func toggleListen() {
        if isListening {
            // Manual stop: capture current transcript and send to AI
            let captured = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            speech.stopListening()
            isListening = false
            if captured.isEmpty {
                state = .idle
                if continuousListening {
                    Task { try? await Task.sleep(nanoseconds: 300_000_000); self.startListening() }
                }
                return
            }
            submitQuestion(captured, auto: false)
        } else {
            startListening()
        }
    }

    func startListening() {
        Task {
            let ok = await ensurePermission()
            guard ok else { return }
            do {
                try speech.startListening(localeIdentifier: speechLocaleIdentifier)
                isListening = true
                state = .listening(transcript: "")
                lastTranscript = ""
            } catch {
                state = .error(error.localizedDescription)
                isListening = false
            }
        }
    }

    func stopAndCancel() {
        speech.cancelAndClear()
        isListening = false
        state = .idle
    }

    func dismissAnswer() {
        lastAnswer = ""
        state = .idle
        browsingIndex = nil
        if continuousListening, !isListening {
            startListening()
        }
    }

    /// The answer the card is currently showing, browsed or live.
    var activeAnswer: String {
        browsedEntry?.answer ?? lastAnswer
    }

    /// Copy whichever answer is on screen, so recalling an old one is useful.
    func copyAnswerToClipboard() {
        let text = activeAnswer
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Put the shown answer into the scrolling script, so it can be read aloud.
    /// Browsed answers are placed after the passage they came from, because
    /// appending to the end of a long script puts it off-screen mid-talk.
    func pushAnswerToScript() {
        let text = activeAnswer
        guard !text.isEmpty else { return }

        if let browsed = browsedEntry {
            let script = prompter.script
            let marker = "\n\n— Answer: \(browsed.question)\n\(text)\n"

            // Place it after the supporting passage when we can find it,
            // otherwise fall back to appending.
            let located = browsed.quote.flatMap {
                ScriptQuoteLocator.locate(quote: $0, in: script)
            }
            if let match = located {
                let end = min(script.count, match.characterIndex + match.matchedLength)
                prompter.script = String(script.prefix(end)) + marker + String(script.dropFirst(end))
            } else {
                prompter.script = script + marker
            }
            return
        }

        let existing = prompter.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = "\n\n— Answer: \(text)"
        prompter.script = existing.isEmpty ? text : existing + entry
    }


    func clearHistory() {
        history.removeAll()
        browsingIndex = nil
    }

    // MARK: - History browsing

    /// Move one step further back through history. No-op at the oldest entry.
    func browseOlder() {
        guard !history.isEmpty else { return }
        let next = min((browsingIndex ?? 0) + 1, history.count - 1)
        browsingIndex = next
        jumpFailed = false
    }

    /// Move one step toward the newest. Reaches the live answer and stops.
    func browseNewer() {
        guard let current = browsingIndex else { return }
        let next = current - 1
        browsingIndex = next < 0 ? nil : next
        jumpFailed = false
    }

    /// Return to showing the live answer.
    func showLatestAnswer() {
        browsingIndex = nil
        jumpFailed = false
    }

    var canBrowseOlder: Bool { !history.isEmpty && (browsingIndex ?? 0) < history.count - 1 }
    var canBrowseNewer: Bool { (browsingIndex ?? 0) > 0 }

    /// Force a gated utterance through to the AI anyway.
    func sendSuppressedAnyway(_ text: String) {
        submitQuestion(text, auto: false)
    }

    /// Re-ask the last question, bypassing the cache. Use when an answer was
    /// right in shape but wrong in substance.
    func refreshLastAnswer() {
        guard !lastQuestion.isEmpty else { return }
        AnswerCache.shared.remove(lastQuestion)
        submitQuestion(lastQuestion, auto: false, forceRefresh: true)
    }

    // MARK: - AI setup panel

    func openAISetup() {
        isAISetupVisible = true
        // Transient height: gives the panel room without touching the user's
        // persisted overlay height.
        if prompter.effectiveOverlayHeight < 380 {
            prompter.transientOverlayHeight = 380
        }
    }

    func closeAISetup() {
        isAISetupVisible = false
        prompter.transientOverlayHeight = nil
    }

    func toggleAISetup() {
        if isAISetupVisible { closeAISetup() } else { openAISetup() }
    }

    // MARK: Private

    /// Jump the teleprompter to the passage the last answer was drawn from.
    ///
    /// Deliberately fails silently into a small notice rather than jumping
    /// somewhere wrong: a bad guess mid-call is worse than no movement.
    func jumpToQuotedLine() {
        jumpFailed = false
        // Honour the browsed entry's quote when reviewing history, otherwise
        // the one from the answer currently on screen.
        let quote = (browsedEntry?.quote ?? lastScriptQuote)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote, !quote.isEmpty else {
            jumpFailed = true
            return
        }

        guard let match = ScriptQuoteLocator.locate(quote: quote, in: prompter.script) else {
            // The model paraphrased past the point of locating it.
            jumpFailed = true
            return
        }

        guard let phase = ScriptTextMapper.phase(
            for: match,
            script: prompter.script,
            snapshot: position.snapshot,
            fontSize: prompter.fontSize
        ) else {
            // Layout has not been measured yet, so any position would be a guess.
            jumpFailed = true
            return
        }

        position.highlight = ScriptHighlight(
            range: match.characterIndex..<(match.characterIndex + match.matchedLength),
            token: UUID()
        )
        position.requestSeek(toPhase: phase)

        // Clear the highlight after a few seconds so it does not linger.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.position.highlight?.range.lowerBound == match.characterIndex {
                self.position.clearHighlight()
            }
        }
    }

    /// Snapshot where the speaker is right now, for the AI prompt.
    ///
    /// Read synchronously on the main actor at the moment the question is
    /// asked, so the context reflects the position the speaker was looking at
    /// when they heard the question.
    private func buildScriptContext() -> ScriptContext? {
        let script = prompter.script
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ScriptTextMapper.makeContext(
            snapshot: ScriptPositionModel.shared.snapshot,
            script: script,
            fontSize: prompter.fontSize
        )
    }

    private func submitQuestion(_ raw: String, auto: Bool, forceRefresh: Bool = false) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count >= 3 else {
            state = isListening ? .listening(transcript: q) : .idle
            return
        }

        // The gate only ever suppresses *automatic* sends. A manual stop always
        // goes through, so the user always has the final say.
        if auto, questionGateEnabled {
            let gate = QuestionGate(minimumWords: questionGateMinWords)
            if gate.decision(for: q) == .suppress {
                // Deliberately return before stopping the mic, so the user can
                // keep talking and the next pause will be judged on its own.
                state = .gateSuppressed(q)
                return
            }
        }

        // Deduplicate rapid auto-fires
        if q == lastQuestion, auto { return }

        lastQuestion = q
        lastTranscript = q
        // Stop listening while thinking so we don't capture our own thinking?
        // But for background mode we keep listening; we stop here to avoid feedback.
        if isListening { speech.stopListening(); isListening = false }

        state = .thinking(question: q)

        Task {
            do {
                let context = buildScriptContext()
                let onDelta: ((String) -> Void)? = streamAnswers
                    ? { partial in
                        // Only promote to streaming once content actually starts;
                        // reasoning tokens must never become the visible answer.
                        if case .thinking = self.state {
                            self.state = .streaming(answer: partial, reasoning: "")
                        } else if case .streaming = self.state {
                            self.state = .streaming(answer: partial, reasoning: self.currentReasoning)
                        }
                    }
                    : nil

                let onReasoning: ((String) -> Void)? = streamAnswers
                    ? { reasoning in
                        self.currentReasoning = reasoning
                    }
                    : nil

                let answer = try await ai.answer(
                    question: q,
                    scriptContext: context,
                    onDelta: onDelta,
                    onReasoning: onReasoning,
                    forceRefresh: forceRefresh,
                    wantsScriptQuote: aiConfig.includeScriptAsContext
                )
                self.currentReasoning = ""
                self.lastScriptQuote = self.ai.lastScriptQuote
                self.lastAnswer = answer
                self.lastProvider = self.ai.lastSuccessfulProvider
                self.lastAnswerWasCached = self.ai.lastAnswerWasCached
                self.state = .answering(answer)
                self.history.insert(
                    ListenHistoryEntry(
                        id: UUID(),
                        question: q,
                        answer: answer,
                        provider: self.lastProvider,
                        quote: self.lastScriptQuote,
                        wasCached: self.lastAnswerWasCached,
                        date: Date()
                    ),
                    at: 0
                )
                if self.history.count > 30 { self.history.removeLast(self.history.count - 30) }
                // A new answer means the previously browsed entry is stale.
                self.browsingIndex = nil

                if self.continuousListening {
                    // Auto-resume listening after brief pause to let user read answer.
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    // Keep answer visible but resume capturing next question.
                    self.startListening()
                }
            } catch {
                self.currentReasoning = ""
                self.state = .error(error.localizedDescription)
                // Allow retry: keep question
                if self.continuousListening {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    self.startListening()
                }
            }
        }
    }
}
