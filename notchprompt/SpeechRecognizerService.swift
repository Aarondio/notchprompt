//
//  SpeechRecognizerService.swift
//  notchprompt
//
//  Speech-to-text for the notch Listen button.
//  Uses Speech framework + AVAudioEngine, with on-device recognition when
//  available and automatic fallback to Apple's servers.
//

import Foundation
import AVFoundation
import Speech
import Combine

enum SpeechRecognizerError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case audioEngineFailed(String)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone or Speech Recognition not authorized. Enable in System Settings → Privacy & Security."
        case .recognizerUnavailable:
            return "Speech recognizer unavailable for this locale."
        case .audioEngineFailed(let message):
            return "Audio engine failed: \(message)"
        case .alreadyRunning:
            return "Already listening."
        }
    }
}

/// Non-isolated delegate target so the `SFSpeechRecognizerDelegate` conformance
/// does not cross the main-actor boundary of the owning service.
private final class SpeechAvailabilityRelay: NSObject, SFSpeechRecognizerDelegate {
    var onChange: ((Bool) -> Void)?

    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        onChange?(available)
    }
}

@MainActor
final class SpeechRecognizerService: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var partialTranscript = ""
    @Published private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @Published private(set) var isMicrophoneAuthorized = false
    @Published private(set) var isRecognizerAvailable = true
    @Published private(set) var lastError: String?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private let availabilityRelay = SpeechAvailabilityRelay()

    private var silenceTimer: AnyCancellable?

    /// Fired after ~`silenceThreshold` of silence when a non-empty transcript exists.
    var onAutoPause: ((String) -> Void)?

    var autoSendOnSilence = true
    var silenceThreshold: TimeInterval = 1.4
    /// Prefer Apple's on-device model when the locale supports it (faster + private).
    var preferOnDeviceRecognition = true

    private let defaultLocaleIdentifier = "en-US"

    override init() {
        super.init()
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        isMicrophoneAuthorized = Self.currentMicrophonePermission()

        availabilityRelay.onChange = { [weak self] available in
            Task { @MainActor in self?.isRecognizerAvailable = available }
        }

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: defaultLocaleIdentifier))
        speechRecognizer?.delegate = availabilityRelay
        isRecognizerAvailable = speechRecognizer?.isAvailable ?? true
    }

    // MARK: - Permissions

    var isAuthorized: Bool {
        authorizationStatus == .authorized && isMicrophoneAuthorized
    }

    private static func currentMicrophonePermission() -> Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Returns true when both speech recognition and microphone are granted.
    /// Already-granted permissions short-circuit without re-prompting.
    func requestAuthorization() async -> Bool {
        if authorizationStatus == .authorized, isMicrophoneAuthorized {
            return true
        }

        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        if authorizationStatus == .authorized {
            speechStatus = .authorized
        } else {
            speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        authorizationStatus = speechStatus

        let micGranted: Bool
        if Self.currentMicrophonePermission() {
            micGranted = true
        } else if #available(macOS 14.0, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        isMicrophoneAuthorized = micGranted

        return speechStatus == .authorized && micGranted
    }

    // MARK: - Start / Stop

    func startListening(localeIdentifier: String? = nil) throws {
        guard !isListening else { throw SpeechRecognizerError.alreadyRunning }
        lastError = nil

        let recognizer: SFSpeechRecognizer
        if let identifier = localeIdentifier,
           let localized = SFSpeechRecognizer(locale: Locale(identifier: identifier)) {
            recognizer = localized
        } else if let existing = speechRecognizer {
            recognizer = existing
        } else if let fallback = SFSpeechRecognizer(locale: Locale(identifier: defaultLocaleIdentifier)) {
            recognizer = fallback
        } else {
            throw SpeechRecognizerError.recognizerUnavailable
        }

        guard recognizer.isAvailable else {
            isRecognizerAvailable = false
            throw SpeechRecognizerError.recognizerUnavailable
        }
        isRecognizerAvailable = true

        guard isAuthorized else { throw SpeechRecognizerError.notAuthorized }

        speechRecognizer = recognizer
        recognizer.delegate = availabilityRelay

        transcript = ""
        partialTranscript = ""

        try startEngine(with: recognizer)
        isListening = true
    }

    func stopListening() {
        guard isListening else { return }
        teardownEngine()
        isListening = false
    }

    func cancelAndClear() {
        teardownEngine()
        isListening = false
        transcript = ""
        partialTranscript = ""
    }

    // MARK: - Engine

    private func startEngine(with recognizer: SFSpeechRecognizer) throws {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Use on-device when the locale supports it; Apple falls back automatically.
        request.requiresOnDeviceRecognition = preferOnDeviceRecognition && recognizer.supportsOnDeviceRecognition

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw SpeechRecognizerError.audioEngineFailed("No input channels")
        }

        self.audioEngine = engine
        self.recognitionRequest = request

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Audio tap runs on a realtime thread; only hand the buffer over.
            self?.recognitionRequest?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngine()
            throw SpeechRecognizerError.audioEngineFailed(error.localizedDescription)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handle(result: result, error: error)
            }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            partialTranscript = text
            transcript = text

            if autoSendOnSilence, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resetSilenceTimer(with: text)
            }
        }

        guard let error else { return }

        // Expected errors during normal teardown — ignore them.
        let nsError = error as NSError
        let isCancellation =
            nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
            || error.localizedDescription.lowercased().contains("cancel")
        if !isCancellation {
            lastError = error.localizedDescription
        }
    }

    private func resetSilenceTimer(with text: String) {
        silenceTimer?.cancel()
        silenceTimer = Just(text)
            .delay(for: .seconds(silenceThreshold), scheduler: RunLoop.main)
            .sink { [weak self] finalText in
                guard let self else { return }
                let isSilent = self.isListening && self.transcript == finalText
                let hasContent = !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isSilent && hasContent {
                    self.onAutoPause?(finalText)
                }
            }
    }

    private func teardownEngine() {
        silenceTimer?.cancel()
        silenceTimer = nil

        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
