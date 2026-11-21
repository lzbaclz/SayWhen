import AVFoundation
import Speech

struct SpeechSpan {
    let start: Double
    let end: Double
    let range: NSRange
}

/// A short, bounded RAM buffer for checking *untranscribed* audio in mixed dictation.
/// Capture-pool buffers are copied, never retained. Discontinuous or long recordings use the primary decoder.
final class UtteranceAudio {
    private let lock = NSLock()
    private var buffers = [AVAudioPCMBuffer]()
    private var frames = 0
    private var disabled = false

    func append(_ sample: CMSampleBuffer) {
        lock.lock()
        let skip = disabled
        lock.unlock()
        guard !skip else { return }
        guard let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, count < 192000, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        copy.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count),
                                                          into: copy.mutableAudioBufferList) == noErr else { return }
        appendOwned(copy)
    }

    // ReplayInput allocates a new immutable buffer for each chunk, as does append(_:) above.
    func appendOwned(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !disabled else { return }
        let count = frames + Int(buffer.frameLength)
        let format = buffer.format
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame) * (format.isInterleaved ? 1 : Int(format.channelCount))
        guard format.sampleRate > 0, Double(count) <= 30 * format.sampleRate, count * bytesPerFrame <= 8 * 1024 * 1024,
              buffers.first.map({ $0.format == format }) ?? true else {
            disabled = true; buffers.removeAll(); frames = 0; return
        }
        buffers.append(buffer)
        frames = count
    }

    struct Gap {
        let insertAt: Int
        let audio: AVAudioPCMBuffer
    }

    func discard() {
        lock.lock(); defer { lock.unlock() }
        disabled = true
        buffers.removeAll()
        frames = 0
    }

    func gap(in text: String, spans: [SpeechSpan]) -> Gap? {
        lock.lock(); defer { lock.unlock() }
        guard !disabled, let format = buffers.first?.format, !spans.isEmpty else { return nil }
        let total = Double(frames) / format.sampleRate
        let string = text as NSString
        var end = 0.0, insertAt = 0
        var gaps = [(start: Double, end: Double, index: Int)]()
        for span in spans {
            guard span.range.location != NSNotFound, NSMaxRange(span.range) <= string.length, span.end > span.start else { return nil }
            if span.start > end { gaps.append((end, span.start, insertAt)) }
            end = max(end, span.end)
            insertAt = NSMaxRange(span.range)
        }
        if total > end { gaps.append((end, total, insertAt)) }
        for gap in gaps.filter({ (0.25...2.2).contains($0.end - $0.start) }).sorted(by: { $0.end - $0.start > $1.end - $1.start }) {
            let start = max(0, Int((gap.start - 0.04) * format.sampleRate))
            let stop = min(frames, Int((gap.end + 0.04) * format.sampleRate))
            guard let audio = slice(start..<max(start, stop), format: format), Self.hasVoicedAudio(audio) else { continue }
            return Gap(insertAt: gap.index, audio: audio)
        }
        return nil
    }

    private func slice(_ range: Range<Int>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !range.isEmpty, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)) else { return nil }
        out.frameLength = AVAudioFrameCount(range.count)
        let dest = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        let stride = Int(format.streamDescription.pointee.mBytesPerFrame)
        var offset = 0
        for chunk in buffers {
            let next = offset + Int(chunk.frameLength)
            let lo = max(offset, range.lowerBound), hi = min(next, range.upperBound)
            if lo < hi {
                let source = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
                for channel in dest.indices {
                    guard let dst = dest[channel].mData, let src = source[channel].mData else { return nil }
                    memcpy(dst.advanced(by: (lo - range.lowerBound) * stride), src.advanced(by: (lo - offset) * stride), (hi - lo) * stride)
                }
            }
            offset = next
            if offset >= range.upperBound { break }
        }
        return out
    }

    private static func hasVoicedAudio(_ audio: AVAudioPCMBuffer) -> Bool {
        let stride = audio.stride
        let sample: (Int) -> Float
        if let data = audio.floatChannelData { sample = { data[0][$0 * stride] } }
        else if let data = audio.int16ChannelData { sample = { Float(data[0][$0 * stride]) / 32768 } }
        else if let data = audio.int32ChannelData { sample = { Float(data[0][$0 * stride]) / 2147483648 } }
        else { return false }
        let window = max(1, Int(audio.format.sampleRate * 0.02))
        // Ignore the padded boundaries, which can contain the neighbouring Chinese syllable.
        let count = Int(audio.frameLength)
        var voiced = 0, offset = window * 3
        while offset + window <= count - window * 3 {
            var energy: Float = 0
            for i in offset..<(offset + window) { let x = sample(i); energy += x * x }
            if energy / Float(window) > 0.0001 { voiced += 1 }
            offset += window
        }
        return voiced >= 5
    }
}

@MainActor final class EnglishWordCheck {
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var token = UUID()
    private var engine: SFSpeechRecognizer?

    enum Result {
        case transcript(String)
        case needsReview(String)
    }

    func check(text: String, spans: [SpeechSpan], recording: UtteranceAudio, vocabulary: SpeechVocabulary,
               budget: TimeInterval, complete: @escaping (Result) -> Void) -> Bool {
        guard budget >= 0.3, let gap = recording.gap(in: text, spans: spans) else { return false }
        if engine == nil { engine = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) }
        guard let engine, engine.isAvailable && engine.supportsOnDeviceRecognition else { return false }
        let id = UUID(); token = id
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .search
        request.contextualStrings = vocabulary.terms
        let source = text as NSString
        let before = source.substring(to: gap.insertAt)
        let after = source.substring(from: gap.insertAt)
        let beforeWords = before.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        let missingObject = ["打开","更新","下载","安装","检查","登录","提交","部署","使用","发送","导出为"].contains(where: beforeWords.hasSuffix)
        let unchecked: Result = missingObject ? .needsReview(text) : .transcript(text)
        func finish(_ value: Result) {
            guard token == id else { return }
            cancel()
            complete(value)
        }
        task = engine.recognitionTask(with: request) { result, error in
            guard result?.isFinal == true || error != nil else { return }
            let heard = result?.bestTranscription.formattedString ?? ""
            let confidence = result?.bestTranscription.segments.map(\.confidence).min() ?? 0
            Task { @MainActor in
                guard self.token == id else { return }
                let term = vocabulary.display(heard.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)))
                guard confidence >= 0.55, vocabulary.terms.contains(term), term.first?.isASCII == true else { finish(unchecked); return }
                guard !before.lowercased().hasSuffix(term.lowercased()), !after.lowercased().hasPrefix(term.lowercased()) else { finish(.transcript(text)); return }
                finish(.transcript((before + " " + term + " " + after).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        request.append(gap.audio)
        request.endAudio()
        timeout = Task {
            try? await Task.sleep(for: .milliseconds(Int(min(1.2, budget) * 1000)))
            if !Task.isCancelled { finish(unchecked) }
        }
        return true
    }

    func cancel() {
        token = UUID()
        timeout?.cancel(); timeout = nil
        task?.cancel(); task = nil
    }
}
