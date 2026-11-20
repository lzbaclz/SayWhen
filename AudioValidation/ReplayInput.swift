import AVFoundation
import Speech
@testable import SayWhen

/// Substitutes recorded PCM for the microphone. The Speech task and release behavior belong to Capture.
final class ReplayInput: SpeechInput {
    let file: AVAudioFile
    let duration: Double
    private let queue = DispatchQueue(label: "local.saywhen.tests.replay")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    var onEnd: (() -> Void)?

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    func start(request: SFSpeechAudioBufferRecognitionRequest, ready: @escaping (Bool) -> Void) {
        queue.async {
            self.request = request
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
            let deadline = started + Double(file.framePosition) / rate
            queue.asyncAfter(deadline: deadline) { self.feed(started: started, ready: ready) }
        } catch { ready(false) }
    }

    func stop() {
        queue.async {
            self.request?.endAudio()
            self.request = nil
        }
    }
}
