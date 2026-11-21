import AVFoundation
import Speech

protocol SpeechInput: AnyObject {
    func start(request: SFSpeechAudioBufferRecognitionRequest, recording: UtteranceAudio?, ready: @escaping (Bool) -> Void)
    func continueWith(_ request: SFSpeechAudioBufferRecognitionRequest)
    func stop()
}

// Session setup and buffer delivery share a serial queue; stop drains earlier buffers before ending speech input.
final class AudioInput: NSObject, SpeechInput, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "local.saywhen.audio-input")
    private var session: AVCaptureSession?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recording: UtteranceAudio?
    private var observers: [NSObjectProtocol] = []

    func start(request: SFSpeechAudioBufferRecognitionRequest, recording: UtteranceAudio?, ready: @escaping (Bool) -> Void) {
        queue.async {
            guard let device = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: device) else { ready(false); return }
            let session = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            guard session.canAddInput(input) else { ready(false); return }
            session.addInput(input)
            guard session.canAddOutput(output) else { ready(false); return }
            session.addOutput(output)
            output.setSampleBufferDelegate(self, queue: self.queue)
            self.request = request
            self.recording = recording
            self.session = session
            for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                self.observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { _ in ready(false) })
            }
            session.startRunning()
            ready(session.isRunning)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        request?.appendAudioSampleBuffer(sampleBuffer)
        recording?.append(sampleBuffer)
    }

    func continueWith(_ request: SFSpeechAudioBufferRecognitionRequest) {
        queue.async {
            guard self.session != nil else { return }
            self.request?.endAudio()
            self.request = request
        }
    }

    func stop() {
        queue.async {
            self.observers.forEach(NotificationCenter.default.removeObserver)
            self.observers.removeAll()
            self.request?.endAudio()
            self.request = nil
            self.recording = nil
            self.session?.stopRunning()
            self.session = nil
        }
    }
}
