import AVFoundation
import Speech
@testable import SayWhen

/// Substitutes recorded PCM for the microphone. The Speech task and release behavior belong to Capture.
final class ReplayInput: SpeechInput {
    let file: AVAudioFile
    let duration: Double
    private let endDelay: TimeInterval
    private let queue = DispatchQueue(label: "local.saywhen.tests.replay")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recording: UtteranceAudio?
    var onEnd: (() -> Void)?

    init(url: URL, endDelay: TimeInterval = 0) throws {
        self.endDelay = endDelay
        file = try AVAudioFile(forReading: url)
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    func start(request: SFSpeechAudioBufferRecognitionRequest, recording: UtteranceAudio?, ready: @escaping (Bool) -> Void) {
        queue.async {
            self.request = request
            self.recording = recording
            ready(true)
            self.feed(started: .now(), ready: ready)
        }
    }

    private func feed(started: DispatchTime, ready: @escaping (Bool) -> Void) {
        guard let request else { return }
        guard file.framePosition < file.length else { onEnd?(); return }
        let rate = file.processingFormat.sampleRate
        let count = AVAudioFrameCount(min(file.length - file.framePosition, Int64(rate / 25)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            ready(false)
            return
        }
        do {
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { ready(false); return }
            request.append(buffer)
            recording?.appendOwned(buffer)
            let deadline = started + Double(file.framePosition) / rate
            queue.asyncAfter(deadline: deadline) { self.feed(started: started, ready: ready) }
        } catch { ready(false) }
    }

    func continueWith(_ request: SFSpeechAudioBufferRecognitionRequest) {
        queue.async {
            guard self.request != nil else { return }
            self.request?.endAudio()
            self.request = request
        }
    }

    func stop() {
        queue.async {
            let closing = self.request
            self.request = nil
            self.recording = nil
            if self.endDelay > 0 {
                self.queue.asyncAfter(deadline: .now() + self.endDelay) { closing?.endAudio() }
            } else { closing?.endAudio() }
        }
    }
}
