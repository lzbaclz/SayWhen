import XCTest
import Speech
@testable import SayWhen

final class AudioTests: XCTestCase {
    func testOnDeviceMandarinAudioFile() throws {
        try XCTSkipUnless(SFSpeechRecognizer.authorizationStatus() == .authorized, "模拟器未获语音识别授权")
        let recognizer = try XCTUnwrap(SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")))
        try XCTSkipUnless(recognizer.supportsOnDeviceRecognition && recognizer.isAvailable, "本机普通话资源不可用")
        let bundle = Bundle(for: AudioTests.self)
        guard let file = bundle.url(forResource: "mandarin", withExtension: "wav", subdirectory: "Audio") else {
            throw XCTSkip("请先按 Tests/Audio/README.md 生成本地语音夹具")
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let done = expectation(description: "普通话端侧识别")
        var transcript = ""
        var failure: Error?
        let job = recognizer.recognitionTask(with: request) { result, error in
            if let error { failure = error; done.fulfill() }
            else if let result, result.isFinal { transcript = result.bestTranscription.formattedString; done.fulfill() }
        }
        defer { job.cancel() }
        wait(for: [done], timeout: 30)
        if let failure {
            let error = failure as NSError
            if error.domain == "kAFAssistantErrorDomain" && [1,102,1100,1101,1107].contains(error.code) {
                throw XCTSkip("系统识别服务不可用，" + error.description)
            }
            throw failure
        }
        print("ON_DEVICE_TRANSCRIPT " + transcript)
        let row = try XCTUnwrap(MandarinParser(now: Date(), zone: .current).parse(transcript).first)
        XCTAssertEqual(row.draft.title, "去复诊")
        XCTAssertEqual(row.draft.due.kind, .timed)
    }
}
