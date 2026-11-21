import AVFoundation
import Speech
import SwiftUI

@MainActor @Observable final class Capture {
    enum Phase { case idle, authorizing, listening, ready, finishing, typing }
    var phase = Phase.idle
    var transcript = ""
    var message = ""
    private(set) var began = Date()
    private(set) var zone = TimeZone.current
    private var sessionID = UUID()
    private var segmentID = UUID()
    private let makeInput: () -> any SpeechInput
    private var input: (any SpeechInput)?
    private var recognition: SFSpeechRecognitionTask?
    private var watchdog: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var recognizerLanguage: SpeechLanguage?
    private var vocabulary = SpeechVocabulary()
    private var compiledModel: SFSpeechLanguageModel.Configuration?
    private var completedText = ""
    private var recording: UtteranceAudio?
    private let englishCheck = EnglishWordCheck()
    private var releasedAt = 0.0
    var onResult: ((String, Date, TimeZone) -> Void)?

    init(makeInput: @escaping () -> any SpeechInput = { AudioInput() }) { self.makeInput = makeInput }

    private func engine(for language: SpeechLanguage) -> SFSpeechRecognizer? {
        let locale = Locale(identifier: language.rawValue)
        if recognizer == nil || recognizerLanguage != language {
            recognizer = SFSpeechRecognizer(locale: locale)
            recognizerLanguage = language
        }
        return recognizer
    }

    func warm(_ preferences: AppPreferences) {
        guard phase == .idle, SFSpeechRecognizer.authorizationStatus() == .authorized,
              engine(for: preferences.language)?.supportsOnDeviceRecognition == true else { return }
        _ = SpeechProfiles.shared.configuration(language: preferences.language, vocabulary: SpeechVocabulary(personal: preferences.vocabulary))
    }

    func start(preferences: AppPreferences = AppPreferences()) {
        cancel()
        began = Date()
        zone = .current
        transcript = ""
        completedText = ""
        phase = .authorizing
        message = "正在准备麦克风…"
        let id = sessionID
        Task {
            guard sessionID == id else { return }
            guard let recognizer = engine(for: preferences.language), recognizer.supportsOnDeviceRecognition else {
                fallback("本机所选语言的识别暂不可用，可以键入或使用键盘听写。"); return
            }
            var permission = SFSpeechRecognizer.authorizationStatus()
            if permission == .notDetermined {
                permission = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
            }
            guard id == sessionID else { return }
            guard permission == .authorized else { fallback("语音识别未授权，可以键入或前往设置。"); return }
            let mic = AVAudioApplication.shared.recordPermission == .undetermined ?
                await AVAudioApplication.requestRecordPermission() : AVAudioApplication.shared.recordPermission == .granted
            guard id == sessionID else { return }
            guard mic && recognizer.isAvailable else { fallback("麦克风或语音识别不可用，可以直接键入。"); return }
            vocabulary = SpeechVocabulary(personal: preferences.vocabulary)
            compiledModel = SpeechProfiles.shared.configuration(language: preferences.language, vocabulary: vocabulary)
            recording = preferences.language == .mandarin ? UtteranceAudio() : nil
            let input = makeInput()
            self.input = input
            beginSegment(recognizer, input: input, continuing: false)
        }
    }

    private func beginSegment(_ engine: SFSpeechRecognizer, input: any SpeechInput, continuing: Bool) {
        let id = sessionID
        let segment = UUID()
        segmentID = segment
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = vocabulary.terms
        request.customizedLanguageModel = compiledModel
        if continuing { input.continueWith(request) }
        else {
            input.start(request: request, recording: recording) { [weak self] running in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if running && self.phase == .authorizing {
                        self.phase = .listening
                        self.message = "正在听"
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } else if !running {
                        self.fallback("当前没有可用的录音输入，请键入或使用键盘听写。")
                    }
                }
            }
        }
        recognition = engine.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let spans = final ? (result?.bestTranscription.segments.map {
                SpeechSpan(start: $0.timestamp, end: $0.timestamp + $0.duration, range: $0.substringRange)
            } ?? []) : []
            Task { @MainActor in
                guard let self, self.sessionID == id, self.segmentID == segment else { return }
                if let text, !text.isEmpty {
                    self.transcript = Self.join(self.completedText, self.vocabulary.display(text))
                }
                if final && self.phase == .finishing {
                    self.segmentID = UUID()
                    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        if !self.completedText.isEmpty && self.transcript == self.completedText { self.submit() }
                        else { self.fallback("未能确认最后的文字，请核对后点完成。") }
                        return
                    }
                    if self.completedText.isEmpty, let audio = self.recording {
                        let remaining = 3 - (ProcessInfo.processInfo.systemUptime - self.releasedAt)
                        let checking = self.englishCheck.check(text: text, spans: spans, recording: audio,
                                                              vocabulary: self.vocabulary, budget: remaining) { [weak self] checked in
                            guard let self, self.sessionID == id, self.phase == .finishing else { return }
                            switch checked {
                            case .transcript(let value):
                                self.transcript = self.vocabulary.display(value)
                                self.submit()
                            case .needsReview(let value):
                                self.transcript = self.vocabulary.display(value)
                                self.fallback("有一段专名没有听清，请核对文字后点完成。")
                            }
                        }
                        if checking { self.watchdog?.cancel(); return }
                    }
                    self.submit()
                }
                else if final, let input = self.input, text?.isEmpty == false {
                    // The recognizer can endpoint during a pause. Keep the mic running until user release.
                    self.completedText = self.transcript
                    self.recording?.discard()
                    self.beginSegment(engine, input: input, continuing: true)
                } else if final && !self.completedText.isEmpty {
                    self.stopInput()
                    self.phase = .ready
                    self.message = "已转写，点完成保存"
                } else if error != nil || final {
                    self.fallback("识别已暂停，可以核对已有文字后保存。")
                }
            }
        }
    }

    private static func join(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        let space = prefix.last?.isASCII == true && suffix.first?.isASCII == true
        return prefix + (space ? " " : "") + suffix
    }

    func finish() {
        guard phase == .listening else {
            if phase == .typing || phase == .ready { submit() }
            else if phase == .authorizing { fallback("麦克风尚未就绪，可以重试或直接键入。") }
            return
        }
        phase = .finishing
        releasedAt = ProcessInfo.processInfo.systemUptime
        message = "正在确认最后几个词…"
        stopInput()
        let id = sessionID
        watchdog = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled && id == sessionID && phase == .finishing else { return }
            fallback(transcript.isEmpty ? "暂未听到内容，可以再说一次或键入。" : "尚未收到最终转写，请核对句尾后点完成。")
        }
    }

    func submit() {
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { fallback("还没有听到内容，可以重试或键入。"); return }
        cancel()
        onResult?(value, began, zone)
    }

    func fallback(_ reason: String) {
        cancel()
        phase = .typing
        message = reason
    }

    func cancel() {
        sessionID = UUID()
        segmentID = UUID()
        watchdog?.cancel()
        watchdog = nil
        englishCheck.cancel()
        recording = nil
        stopInput()
        recognition?.cancel()
        recognition = nil
        phase = .idle
    }

    private func stopInput() { input?.stop(); input = nil }
}
