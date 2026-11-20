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
    private let makeInput: () -> any SpeechInput
    private var input: (any SpeechInput)?
    private var recognition: SFSpeechRecognitionTask?
    private var watchdog: Task<Void, Never>?
    var onResult: ((String, Date, TimeZone) -> Void)?

    init(makeInput: @escaping () -> any SpeechInput = { AudioInput() }) {
        self.makeInput = makeInput
    }

    func start() {
        cancel()
        began = Date()
        zone = .current
        transcript = ""
        phase = .authorizing
        message = "正在准备麦克风…"
        let id = sessionID
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            guard sessionID == id else { return }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
                  recognizer.supportsOnDeviceRecognition else {
                fallback("本机普通话识别暂不可用，可以键入或使用键盘听写。"); return
            }
            let permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard id == sessionID else { return }
            guard permission == .authorized else { fallback("语音识别未授权，可以键入或前往设置。"); return }
            let mic = await AVAudioApplication.requestRecordPermission()
            guard id == sessionID else { return }
            guard mic && recognizer.isAvailable else { fallback("麦克风或语音识别不可用，可以直接键入。"); return }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            let input = makeInput()
            self.input = input
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if let text { self.transcript = text }
                    if final {
                        if self.phase == .finishing { self.submit() }
                        else {
                            self.stopInput()
                            self.phase = .ready
                            self.message = "已转写，点完成保存"
                        }
                    }
                    else if error != nil { self.fallback("识别中断，可以编辑已有文字后保存。") }
                }
            }
            input.start(request: request) { [weak self] running in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    if running && self.phase == .authorizing {
                        self.phase = .listening
                        self.message = "正在听"
                    } else if !running {
                        self.fallback("当前没有可用的录音输入，请键入或使用键盘听写。")
                    }
                }
            }
        }
    }

    func finish() {
        guard phase == .listening else {
            if phase == .typing || phase == .ready { submit() }
            else if phase == .authorizing { fallback("准备好了再说一次，或直接键入。") }
            return
        }
        phase = .finishing
        message = "正在整理…"
        stopInput()
        let id = sessionID
        watchdog = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled && id == sessionID else { return }
            submit()
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
        watchdog?.cancel()
        watchdog = nil
        stopInput()
        recognition?.cancel()
        recognition = nil
        phase = .idle
    }

    private func stopInput() {
        input?.stop()
        input = nil
    }
}
