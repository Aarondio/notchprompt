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

@MainActor
final class ListenModel: ObservableObject {
    static let shared = ListenModel()

    @Published private(set) var state: ListenState = .idle
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var lastAnswer: String = ""
    @Published private(set) var lastQuestion: String = ""
    @Published private(set) var lastProvider: String?
    @Published private(set) var isListening = false

    /// History for debugging / future list view
    @Published private(set) var history: [(question: String, answer: String, provider: String?, date: Date)] = []

    /// Settings
    @Published var autoSendOnSilence: Bool = true {
        didSet { speech.autoSendOnSilence = autoSendOnSilence }
    }
    @Published var continuousListening: Bool = false // if true, auto-restart listening after each answer
    @Published var showAnswerInNotch: Bool = true
    /// Stream answers so the first words appear immediately. Turn off to force
    /// a single non-streamed response.
    @Published var streamAnswers: Bool = true
    /// Skip small talk instead of spending a request on it.
    @Published var questionGateEnabled: Bool = true
    /// Utterance length at or above which we send regardless of wording.
    @Published var questionGateMinWords: Int = 6
    /// How long a pause must be before an utterance is considered finished.
    @Published var silenceThreshold: TimeInterval = 1.4 {
        didSet { speech.silenceThreshold = silenceThreshold }
    }

    /// Notch-native AI provider/key setup panel.
    @Published var isAISetupVisible = false

    private let speech = SpeechRecognizerService()
    private let ai = AIService.shared
    private let prompter = PrompterModel.shared

    /// Latest accumulated reasoning text, kept out of the visible answer.
    private var currentReasoning: String = ""

    private var cancellables: Set<AnyCancellable> = []

    private init() {
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
                try speech.startListening()
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
        if continuousListening, !isListening {
            startListening()
        }
    }

    func copyAnswerToClipboard() {
        guard !lastAnswer.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastAnswer, forType: .string)
    }

    func pushAnswerToScript() {
        guard !lastAnswer.isEmpty else { return }
        // Append answer to script so it scrolls — handy for delivery.
        let existing = prompter.script.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = "\n\n— Answer: \(lastAnswer)"
        if existing.isEmpty {
            prompter.script = lastAnswer
        } else {
            prompter.script = existing + entry
        }
    }

    func clearHistory() { history.removeAll() }

    /// Force a gated utterance through to the AI anyway.
    func sendSuppressedAnyway(_ text: String) {
        submitQuestion(text, auto: false)
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

    private func submitQuestion(_ raw: String, auto: Bool) {
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
                let scriptCtx = prompter.script
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
                    scriptContext: scriptCtx,
                    onDelta: onDelta,
                    onReasoning: onReasoning
                )
                self.currentReasoning = ""
                self.lastAnswer = answer
                self.lastProvider = self.ai.lastSuccessfulProvider
                self.state = .answering(answer)
                self.history.insert((q, answer, self.lastProvider, Date()), at: 0)
                if self.history.count > 30 { self.history.removeLast(self.history.count - 30) }

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
