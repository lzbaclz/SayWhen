import XCTest
import Speech
import SwiftUI
import SwiftData
import UserNotifications
@testable import SayWhen

private struct Clip: Decodable {
    let id: String
    let corpus: String
    let file: String
    let speaker: String
    let reference: String
    let condition: String
}

private struct ParsedRow: Encodable {
    let title: String
    let notes: String
    let dateKind: String
    let localDate: String?
    let rule: String
    let question: String?
    let reminder: String?
    let retainedDay: String?

    init(_ row: ParsedTask, at now: Date) {
        let due = row.draft.due
        title = row.draft.title
        notes = row.draft.notes
        dateKind = due.kind.rawValue
        localDate = due.kind == .none ? nil : Due.format(due.date, zone: due.calendar.timeZone,
                                                        pattern: due.kind == .allDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm")
        rule = row.draft.rule.rawValue
        question = row.question
        retainedDay = row.missingTime.map { Due.format($0.day, zone: due.calendar.timeZone, pattern: "yyyy-MM-dd") }
        reminder = row.question == nil ? row.draft.nextReminder(after: now).map {
            Due.format($0, zone: due.calendar.timeZone, pattern: "yyyy-MM-dd HH:mm")
        } : nil
    }
}

private struct Observation: Encodable {
    let id: String
    let speaker: String
    let condition: String
    let seconds: Double
    let reference: String
    let transcript: String
    let route: String
    let message: String?
    let releaseToRouteMS: Double?
    let rows: [ParsedRow]
    let parsedReference: [ParsedRow]
}

@MainActor private final class IsolatedNotifications: ReminderCenter {
    func permission() async -> UNAuthorizationStatus { .denied }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { false }
    func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }
    func add(_ request: UNNotificationRequest) async throws { XCTFail("测试清单不应写入系统通知") }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}

@MainActor final class RecordedSpeechTests: XCTestCase {
    private let parser = MandarinParser(now: Date(timeIntervalSince1970: 1795140000),
                                        zone: TimeZone(identifier: "Asia/Shanghai")!)
    private var evidence = [Observation]()

    override func tearDown() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(evidence) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "recorded-speech.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        super.tearDown()
    }

    private func fixtures() throws -> (URL, [Clip]) {
        let folder = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appending(path: "Fixtures")
        let manifest = folder.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw XCTSkip("此专项需要自行准备获许可的录音及 Fixtures/manifest.json")
        }
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: manifest))
        XCTAssertFalse(clips.isEmpty)
        return (folder, clips)
    }

    private func run(_ clips: [Clip], in folder: URL) async throws {
        XCTAssertEqual(SFSpeechRecognizer.authorizationStatus(), .authorized)
        let store = try TaskStore(LocalDatabase.open(configuration: ModelConfiguration(isStoredInMemoryOnly: true)),
                                  center: IsolatedNotifications())
        var unavailable = 0
        for clip in clips {
            let source = try ReplayInput(url: folder.appending(path: clip.file))
            let capture = Capture(makeInput: { source })
            var submitted: String?
            var release: Double?
            capture.onResult = { text, _, _ in submitted = text }
            func releaseCapture() {
                guard release == nil else { return }
                release = ProcessInfo.processInfo.systemUptime
                capture.finish()
            }
            source.onEnd = { Task { @MainActor in releaseCapture() } }
            capture.start()
            let start = ProcessInfo.processInfo.systemUptime
            while submitted == nil && capture.phase != .typing && ProcessInfo.processInfo.systemUptime - start < source.duration + 10 {
                if capture.phase == .ready { releaseCapture() }
                try await Task.sleep(for: .milliseconds(15))
            }
            let text = submitted ?? capture.transcript
            let rows = submitted.map { parser.parse($0) } ?? []
            var route = "fallback"
            if let draft = MandarinParser.directDraft(from: rows) {
                let item = try XCTUnwrap(store.insert([draft]).first)
                XCTAssertEqual(try store.item(id: item.id)?.title, draft.title.trimmingCharacters(in: .whitespacesAndNewlines))
                route = "saved"
            } else if submitted != nil { route = "review" }
            let elapsed = release.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 }
            evidence.append(Observation(id: clip.id, speaker: clip.speaker, condition: clip.condition,
                                        seconds: source.duration, reference: clip.reference, transcript: text,
                                        route: route, message: submitted == nil ? capture.message : nil,
                                        releaseToRouteMS: elapsed, rows: rows.map { ParsedRow($0, at: parser.now) },
                                        parsedReference: parser.parse(clip.reference).map { ParsedRow($0, at: parser.now) }))
            print("REPLAY \(evidence.count)/\(clips.count) \(clip.id) \(route) \(text)")
            capture.cancel()
            source.onEnd = nil
            unavailable = submitted == nil ? unavailable + 1 : 0
            if unavailable == 3 { XCTFail("连续三段没有产生可提交的转写，已停止回放"); return }
        }
        XCTAssertEqual(evidence.count, clips.count)
    }

    func testRecordingAppearsInTheTaskList() async throws {
        let (folder, clips) = try fixtures()
        let clip = try XCTUnwrap(clips.first { $0.id == "5_2197_20170630085624" })
        let input = try ReplayInput(url: folder.appending(path: clip.file))
        let capture = Capture(makeInput: { input })
        let store = try TaskStore(LocalDatabase.open(configuration: ModelConfiguration(isStoredInMemoryOnly: true)),
                                  center: IsolatedNotifications())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TaskList(store: store, capture: capture)
            .environment(\.locale, Locale(identifier: "zh_CN")))
        window.makeKeyAndVisible()
        defer { capture.cancel(); input.onEnd = nil; window.isHidden = true; previous?.makeKeyAndVisible() }
        for _ in 0..<100 where capture.onResult == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(capture.onResult)
        input.onEnd = { Task { @MainActor in capture.finish() } }
        capture.start()
        let deadline = ProcessInfo.processInfo.systemUptime + input.duration + 10
        while store.openItems.isEmpty && ProcessInfo.processInfo.systemUptime < deadline && capture.phase != .typing {
            if capture.phase == .ready { capture.finish() }
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try XCTUnwrap(store.openItems.first, capture.message)
        XCTAssertEqual(store.openItems.count, 1)
        XCTAssertEqual(item.title, "赶火车")
        XCTAssertEqual(item.draft.rule, .atDue)
        XCTAssertEqual(item.desiredReminder, item.time)
        let calendar = item.draft.due.calendar
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: item.time), DateComponents(hour: 9, minute: 0))
        XCTAssertTrue(calendar.isDate(item.time, inSameDayAs: try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: capture.began))))
        try await Task.sleep(for: .milliseconds(250))
        let screen = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let image = XCTAttachment(data: screen, uniformTypeIdentifier: "public.png")
        image.name = "真人录音生成待办.png"
        image.lifetime = .keepAlways
        add(image)
    }

    func testTrafficComparison() async throws {
        let (folder, clips) = try fixtures()
        let pairs = clips.filter { $0.corpus == "AISHELL-1" }
        XCTAssertEqual(pairs.count, 24)
        try await run(pairs, in: folder)
    }

    func testDailyInstructions() async throws {
        let (folder, clips) = try fixtures()
        let daily = clips.filter { $0.corpus == "MAGICDATA" }
        XCTAssertEqual(daily.count, 60)
        XCTAssertGreaterThanOrEqual(Set(daily.map(\.speaker)).count, 6)
        try await run(daily, in: folder)
    }
}
