import XCTest
import Speech
@testable import SayWhen

@MainActor final class MixedSpeechTests: XCTestCase {
    private struct Clip: Codable {
        let file: String
        let term: String
        let reference: String
    }

    private struct ResultRow: Codable {
        let clip: Clip
        let transcript: String
        let firstPartialMS: Int?
        let termVisibleMS: Int?
        let releaseMS: Int?
        let termPreserved: Bool
        let route: String
        let title: String
    }

    func testDelayedFinalAndTimeoutKeepTheLastWordsEditable() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appending(path: "Fixtures/Mixed/slides.wav")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("请先生成中英混合录音夹具") }
        for delay in [1.3, 4.5] {
            let input = try ReplayInput(url: file, endDelay: delay)
            let capture = Capture(makeInput: { input })
            var submitted: String?
            var release: TimeInterval?
            capture.onResult = { text, _, _ in submitted = text }
            input.onEnd = { Task { @MainActor in
                release = ProcessInfo.processInfo.systemUptime
                capture.finish()
            } }
            capture.start()
            let deadline = ProcessInfo.processInfo.systemUptime + input.duration + 8
            while release == nil && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let lifted = try XCTUnwrap(release)
            while ProcessInfo.processInfo.systemUptime - lifted < 1.0 { try await Task.sleep(for: .milliseconds(15)) }
            XCTAssertNil(submitted, "900 毫秒后的中间结果不能被自动记入清单")
            XCTAssertEqual(capture.phase, .finishing)
            while submitted == nil && capture.phase == .finishing && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if delay < 3 {
                XCTAssertTrue(try XCTUnwrap(submitted).contains("PPT"))
            } else {
                XCTAssertNil(submitted)
                XCTAssertEqual(capture.phase, .typing)
                XCTAssertFalse(capture.transcript.isEmpty)
                capture.transcript = "准备 PPT 演示"
                capture.submit()
                XCTAssertEqual(submitted, "准备 PPT 演示")
            }
            capture.cancel()
            input.onEnd = nil
        }
    }

    func testMixedMandarinEnglishStream() async throws {
        let dir = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appending(path: "Fixtures/Mixed")
        let index = dir.appending(path: "index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { throw XCTSkip("请先生成中英混合录音夹具") }
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: index))
        var rows = [ResultRow]()
        let parser = MandarinParser(now: Date(timeIntervalSince1970: 1795309860), zone: TimeZone(identifier: "Asia/Shanghai")!)
        func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
        for clip in clips {
            let input = try ReplayInput(url: dir.appending(path: clip.file))
            let capture = Capture(makeInput: { input })
            var output: String?
            var release: Double?
            capture.onResult = { result, _, _ in output = result }
            input.onEnd = { Task { @MainActor in
                guard release == nil else { return }
                release = uptime()
                capture.finish()
            } }
            let start = uptime()
            var first: Int?, english: Int?
            capture.start()
            while output == nil && capture.phase != .typing && uptime() - start < input.duration + 10 {
                let ms = Int((uptime() - start) * 1000)
                if first == nil && !capture.transcript.isEmpty { first = ms }
                if release == nil && english == nil && capture.transcript.localizedCaseInsensitiveContains(clip.term) { english = ms }
                if capture.phase == .ready && release == nil { release = uptime(); capture.finish() }
                try await Task.sleep(for: .milliseconds(15))
            }
            let actual = output ?? capture.transcript
            let parsed = parser.parse(actual)
            let route = output == nil ? "edit" : (MandarinParser.directDraft(from: parsed) == nil ? "review" : "save")
            rows.append(ResultRow(clip: clip, transcript: actual, firstPartialMS: first, termVisibleMS: english,
                                  releaseMS: release.map { Int((uptime() - $0) * 1000) },
                                  termPreserved: actual.localizedCaseInsensitiveContains(clip.term), route: route,
                                  title: parsed.map(\.draft.title).joined(separator: " / ")))
            print("MIXED", clip.file, route, actual)
            capture.cancel()
            input.onEnd = nil
            XCTAssertFalse(actual.isEmpty, clip.file)
            if rows.suffix(3).count == 3 && rows.suffix(3).allSatisfy({ $0.transcript.isEmpty }) { break }
        }
        let data = try JSONEncoder().encode(rows)
        let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        proof.name = "mixed-speech.json"; proof.lifetime = .keepAlways; add(proof)
        XCTAssertEqual(rows.count, clips.count)
    }
}
