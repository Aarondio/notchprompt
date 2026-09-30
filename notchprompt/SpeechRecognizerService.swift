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
    /// The language is not supported at all on this Mac.
    case localeNotSupported(String)
    /// The language is supported but its assets are not downloaded.
    case localeNotInstalled(String)
    case audioEngineFailed(String)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone or Speech Recognition not authorized. Enable in System Settings → Privacy & Security."
        case .recognizerUnavailable:
            return "Speech recognizer unavailable right now."
        case .localeNotSupported(let identifier):
            return "\"\(identifier)\" is not a language this Mac can recognise. Pick another in Settings → Listen & AI."
        case .localeNotInstalled(let identifier):
            return "Speech recognition for \(identifier) is not downloaded. Add it in System Settings → Keyboard → Dictation, or choose another language."
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

/// A language offered for speech recognition.
struct SpeechLocale: Identifiable, Hashable {
    let id: String
    let name: String
    let englishName: String

    static let systemDefault = SpeechLocale(id: "", name: "System default", englishName: "System default")

    /// Curated set covering the languages most likely to be spoken on a call.
    /// A custom code can still be typed for anything not listed.
    static let common: [SpeechLocale] = [
        SpeechLocale(id: "en-US", name: "English (US)", englishName: "English (US)"),
        SpeechLocale(id: "en-GB", name: "English (UK)", englishName: "English (UK)"),
        SpeechLocale(id: "en-AU", name: "English (Australia)", englishName: "English (Australia)"),
        SpeechLocale(id: "en-IN", name: "English (India)", englishName: "English (India)"),
        SpeechLocale(id: "es-ES", name: "Español (España)", englishName: "Spanish (Spain)"),
        SpeechLocale(id: "es-MX", name: "Español (México)", englishName: "Spanish (Mexico)"),
        SpeechLocale(id: "fr-FR", name: "Français (France)", englishName: "French (France)"),
        SpeechLocale(id: "de-DE", name: "Deutsch", englishName: "German"),
        SpeechLocale(id: "pt-BR", name: "Português (Brasil)", englishName: "Portuguese (Brazil)"),
        SpeechLocale(id: "it-IT", name: "Italiano", englishName: "Italian"),
        SpeechLocale(id: "nl-NL", name: "Nederlands", englishName: "Dutch"),
        SpeechLocale(id: "pl-PL", name: "Polski", englishName: "Polish"),
        SpeechLocale(id: "tr-TR", name: "Türkçe", englishName: "Turkish"),
        SpeechLocale(id: "ar-SA", name: "العربية", englishName: "Arabic"),
        SpeechLocale(id: "hi-IN", name: "हिन्दी", englishName: "Hindi"),
        SpeechLocale(id: "ja-JP", name: "日本語", englishName: "Japanese"),
        SpeechLocale(id: "ko-KR", name: "한국어", englishName: "Korean"),
        SpeechLocale(id: "zh-Hans", name: "中文 (简体)", englishName: "Chinese (Simplified)"),
        SpeechLocale(id: "zh-Hant", name: "中文 (繁體)", englishName: "Chinese (Traditional)")
    ]

    static var all: [SpeechLocale] { [.systemDefault] + common }

    /// Resolve a stored identifier to one of the offered locales, so a saved
    /// value that is no longer listed still round-trips instead of resetting.
    static func resolve(_ identifier: String) -> SpeechLocale {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .systemDefault }
        return all.first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame } ?? custom(trimmed)
    }

    static func custom(_ identifier: String) -> SpeechLocale {
        SpeechLocale(id: identifier, name: identifier, englishName: identifier)
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
    /// Locale the last listening attempt used, for diagnostics in the UI.
    @Published private(set) var activeLocaleIdentifier: String = ""

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

    /// The locale used when the user has chosen "System default".
    ///
    /// This deliberately follows macOS instead of being pinned to a constant.
    /// A hardcoded `en-US` meant a user whose system language was, say, French
    /// got English transcription while the picker claimed to follow the system.
    nonisolated private static var systemLocaleIdentifier: String {
        SFSpeechRecognizer()?.locale.identifier ?? Locale.current.identifier
    }

    /// Resolves what the UI and diagnostics should report for a requested locale.
    ///
    /// Extracted from `startListening(localeIdentifier:)` so the empty-means-
    /// system-default rule is testable without the Speech framework, which has
    /// no injectable seam. `nonisolated` because the rule is pure logic and must
    /// be assertable without a main-actor hop.
    nonisolated static func resolvedLocaleIdentifier(
        for requested: String?,
        systemLocale: () -> String = { SpeechRecognizerService.systemLocaleIdentifier }
    ) -> String {
        let trimmed = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? systemLocale() : trimmed
    }

    override init() {
        super.init()
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        isMicrophoneAuthorized = Self.currentMicrophonePermission()

        availabilityRelay.onChange = { [weak self] available in
            Task { @MainActor in self?.isRecognizerAvailable = available }
        }

        // Placeholder recognizer in the system locale. The real one is built in
        // `startListening(localeIdentifier:)`, which is what honours the user's
        // chosen language.
        speechRecognizer = SFSpeechRecognizer()
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

        // An empty identifier means "use the system default", which is what a
        // user who has not chosen a language should get.
        let requested = (localeIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        activeLocaleIdentifier = Self.resolvedLocaleIdentifier(for: requested)

        let recognizer: SFSpeechRecognizer
        if requested.isEmpty {
            // Ask the system rather than constructing from an identifier: this is
            // what honours the user's speech-recognition language setting.
            guard let systemRecognizer = SFSpeechRecognizer() else {
                isRecognizerAvailable = false
                throw SpeechRecognizerError.localeNotSupported(activeLocaleIdentifier)
            }
            recognizer = systemRecognizer
        } else if let localized = SFSpeechRecognizer(locale: Locale(identifier: requested)) {
            recognizer = localized
        } else {
            // The language is not supported at all on this machine.
            isRecognizerAvailable = false
            throw SpeechRecognizerError.localeNotSupported(activeLocaleIdentifier)
        }

        guard recognizer.isAvailable else {
            // Recognised but not downloaded. Say so, rather than silently
            // transcribing in the wrong language.
            isRecognizerAvailable = false
            throw SpeechRecognizerError.localeNotInstalled(activeLocaleIdentifier)
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
