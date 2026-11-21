import XCTest
import SwiftData
import EventKit
import UserNotifications
@testable import SayWhen

final class TaskTests: XCTestCase {
    let zone = TimeZone(identifier: "Asia/Shanghai")!
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testTwoHundredLabeledMandarinInputs() throws {
        let parser = MandarinParser(now: date("2026-11-20T02:00:00Z"), zone: zone)
        let actions = ["去复诊","交报名表","打电话给王洁","寄快递","买苹果和牛奶","取眼镜","提交设计稿","预约牙医","给花浇水","接小陈"]
        let days = [("明天",21),("后天",22),("下周三",25),("周五",20),("十一月二十九日",29)]
        let styles = [("",0),("早上八点",8),("下午三点半",15),("晚上八点",20)]
        var count = 0
        for (i, action) in actions.enumerated() {
            for (word, day) in days {
                for (clock, hour) in styles {
                    let note = "带上\(i + 1)号文件和李医生的回执"
                    let lead = hour == 8 ? "，提前两小时提醒" : ""
                    let input = word + clock + action + lead + "，备注" + note
                    let rows = parser.parse(input)
                    XCTAssertEqual(rows.count, 1, input)
                    let entry = try XCTUnwrap(rows.first)
                    XCTAssertNil(entry.question, input)
                    XCTAssertEqual(entry.draft.title, action, input)
                    XCTAssertEqual(entry.draft.notes, note, input)
                    let due = entry.draft.due
                    XCTAssertEqual(due.kind, clock.isEmpty ? .allDay : .timed, input)
                    XCTAssertEqual(due.calendar.component(.day, from: due.date), day, input)
                    XCTAssertEqual(due.calendar.component(.hour, from: due.date), hour, input)
                    XCTAssertEqual(due.calendar.component(.minute, from: due.date), hour == 15 ? 30 : 0, input)
                    XCTAssertEqual(entry.draft.rule, hour == 8 ? .lead : .followDefault, input)
                    if hour == 8 { XCTAssertEqual(entry.draft.leadMinutes, 120) }
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, 200)
    }

    func testCorrectionAmbiguityMultipleAndUndated() throws {
        let parser = MandarinParser(now: date("2026-11-20T02:00:00Z"), zone: zone)
        let correct = parser.parse("周三，不对，周四下午三点去复诊")
        XCTAssertEqual(correct.count, 1)
        XCTAssertNil(correct[0].question)
        XCTAssertEqual(correct[0].draft.title, "去复诊")
        XCTAssertEqual(correct[0].draft.due.date, date("2026-11-26T07:00:00Z"))
        for input in ["周五之前交表","提醒我找个时间回电话","下周末去公园","过几天看书"] {
            let row = parser.parse(input)[0]
            XCTAssertNotNil(row.question, input)
            XCTAssertEqual(row.draft.due.kind, .none, input)
        }
        let multi = parser.parse("明天寄快递，后天下午三点去复诊，备注带上123号单子")
        XCTAssertEqual(multi.map(\.draft.title), ["寄快递","去复诊"])
        XCTAssertEqual(multi[1].draft.notes, "带上123号单子")
        let separateNotes = parser.parse("明天寄快递，备注一号单子，另外一件事后天取书，备注先登记然后再取书")
        XCTAssertEqual(separateNotes.map(\.draft.notes), ["一号单子", "先登记然后再取书"])
        let plain = parser.parse("买苹果和牛奶")
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain[0].draft.due.kind, .none)
        XCTAssertNil(plain[0].question)
    }

    func testCalendarDayArithmeticAcrossYearAndDST() {
        var draft = Draft(title: "复诊", due: Due(kind: .timed, date: date("2027-01-01T07:00:00Z"), zone: zone.identifier), rule: .previousDay)
        XCTAssertEqual(draft.nextReminder(after: .distantPast), date("2026-12-31T07:00:00Z"))
        draft.due.kind = .allDay
        XCTAssertEqual(draft.nextReminder(after: .distantPast), date("2026-12-31T12:00:00Z"))
        XCTAssertNil(draft.nextReminder(after: date("2027-01-01T00:00:00Z")))
        draft.due = Due(kind: .timed, date: date("2027-03-14T19:00:00Z"), zone: "America/New_York")
        XCTAssertEqual(draft.nextReminder(after: .distantPast), date("2027-03-13T20:00:00Z"))
        XCTAssertEqual(draft.nextReminder(after: date("2027-03-14T12:00:00Z")), draft.due.date)
        XCTAssertNil(draft.nextReminder(after: draft.due.date))
    }

    @MainActor func makeStore() throws -> TaskStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try TaskStore(LocalDatabase.open(configuration: config))
    }

    @MainActor func testPaginationAndPersistentDetails() throws {
        let store = try makeStore()
        var drafts = (0..<1000).map { Draft(title: "事项 \($0)", notes: "第一行\n第二行") }
        drafts[0].due = Due(kind: .timed, date: Date().addingTimeInterval(6000), zone: zone.identifier)
        drafts[0].rule = .off
        drafts[1].due = drafts[0].due
        drafts[1].due.kind = .allDay
        drafts[1].rule = .off
        for (index, draft) in drafts.enumerated() {
            let item = Item(draft)
            if index >= 200 { item.toggle() }
            store.context.insert(item)
        }
        try store.commit()
        let fresh = try TaskStore(store.context.container)
        let page = try fresh.page(done: false, limit: 40)
        XCTAssertEqual(page.count, 40)
        XCTAssertEqual(page.prefix(2).map(\.title), ["事项 1","事项 0"])
        XCTAssertEqual(page[0].notes, "第一行\n第二行")
        XCTAssertEqual(try fresh.page(done: true, limit: 1000).count, 800)
        XCTAssertEqual(try fresh.page(done: false, limit: 1000).count, 200)
    }

    @MainActor func testRealEventKitCreateUpdateConflictAndRecovery() async throws {
        try XCTSkipUnless(EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                          "先运行真实系统授权 UI 用例，再核验 EventKit 写入")
        let service = CalendarSync()
        let list = try await service.calendars()
        let target = try XCTUnwrap(service.events.defaultCalendarForNewEvents ?? list.first)
        let store = try makeStore()
        var draft = Draft(title: "说到集成测试", notes: "原备注", due: Due(kind: .timed, date: Date().addingTimeInterval(864000), zone: zone.identifier))
        draft.rule = .off
        let item = try XCTUnwrap(store.insert([draft]).first)
        func write() throws { try service.write(item, to: target, in: store) }
        func event() throws -> EKEvent {
            try XCTUnwrap(item.receipt?.eventID.flatMap { service.events.event(withIdentifier: $0) })
        }
        try write()
        let original = try event()
        defer {
            if let id = item.receipt?.eventID, let last = service.events.event(withIdentifier: id) {
                try? service.events.remove(last, span: .thisEvent)
            }
        }
        let originalID = original.eventIdentifier
        XCTAssertEqual(original.endDate.timeIntervalSince(original.startDate), 900)
        XCTAssertTrue(original.alarms?.isEmpty ?? true)
        try write()
        XCTAssertEqual(try event().eventIdentifier, originalID)
        original.notes = "日历端备注"
        original.addAlarm(EKAlarm(relativeOffset: -300))
        try service.events.save(original, span: .thisEvent)
        draft.title += "（更新）"
        try store.update(item, with: draft)
        try write()
        XCTAssertEqual(try event().notes, "日历端备注")
        draft.notes = ""
        try store.update(item, with: draft)
        XCTAssertThrowsError(try write()) { error in
            guard case SyncFailure.conflict(let diff, _) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(diff[0].contains("日历端备注"))
        }
        try service.write(item, to: target, in: store, confirmedRemote: EventFields(try event()))
        XCTAssertTrue(try event().notes?.isEmpty ?? true)
        XCTAssertEqual(try event().alarms?.count, 1)
        draft.due.kind = .allDay
        draft.due.zone = "Pacific/Honolulu"
        try store.update(item, with: draft)
        try write()
        XCTAssertTrue(try event().isAllDay)
        XCTAssertEqual(EventFields(try event()).time, EventFields(item).time)
        // Simulate termination after the first EventKit write but before its receipt.
        var intent = try XCTUnwrap(item.receipt)
        intent.eventID = nil
        intent.intent = EventFields(item)
        intent.remote = nil
        intent.local = nil
        intent.syncedAt = nil
        item.calendarLink = try JSONEncoder().encode(intent)
        try store.commit()
        try write()
        XCTAssertEqual(try event().eventIdentifier, originalID)
        let probe = service.events.predicateForEvents(withStart: draft.due.date.addingTimeInterval(-172800), end: draft.due.date.addingTimeInterval(172800), calendars: [target])
        XCTAssertEqual(service.events.events(matching: probe).filter { $0.url?.lastPathComponent == item.id.uuidString }.count, 1)
        try service.events.remove(try event(), span: .thisEvent)
        XCTAssertThrowsError(try write()) { guard case SyncFailure.lost = $0 else { return XCTFail("\($0)") } }
    }
}


extension TaskTests {
    @MainActor func testRealNotificationDeliveryAndReplacement() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        try XCTSkipUnless(settings.authorizationStatus == .authorized, "先在此测试模拟器运行系统授权 UI 用例")
        let store = try makeStore()
        let now = Date()
        let parser = MandarinParser(now: now, zone: zone)
        var draft = try XCTUnwrap(MandarinParser.directDraft(from: parser.parse("大后天早上九点提醒我测试通知")))
        XCTAssertEqual(draft.rule, .atDue)
        let item = try XCTUnwrap(store.insert([draft]).first)
        let id = "saywhen." + item.id.uuidString
        defer {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
        func checkPending(_ expected: Date?) async -> Bool {
            for _ in 0..<35 {
                let matches = await center.pendingNotificationRequests().filter { $0.identifier == id }
                if let expected {
                    if matches.count == 1, let next = (matches[0].trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(),
                       abs(next.timeIntervalSince(expected)) < 1 { return true }
                } else if matches.isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(90))
            }
            return false
        }
        var correct = await checkPending(draft.due.date)
        XCTAssertTrue(correct)
        var follower = draft
        follower.rule = .followDefault
        try store.update(item, with: follower)
        let previousEvening = try XCTUnwrap(DefaultAdvance.previousEvening.time(for: follower.due))
        correct = await checkPending(previousEvening)
        XCTAssertTrue(correct, "系统中只有一个前晚 20:00 的待发通知")
        try store.savePreferences(AppPreferences(advance: .minutes(120)))
        correct = await checkPending(follower.due.date.addingTimeInterval(-7200))
        XCTAssertTrue(correct)
        follower.rule = .lead
        follower.leadMinutes = 15
        try store.update(item, with: follower)
        try store.savePreferences(AppPreferences(advance: .minutes(90)))
        correct = await checkPending(follower.due.date.addingTimeInterval(-900))
        XCTAssertTrue(correct, "单条提前十五分钟应覆盖全局设置，且不重复排程")
        try store.update(item, with: draft)
        correct = await checkPending(draft.due.date)
        XCTAssertTrue(correct)
        var edit = ReminderEdit(draft: draft, scheduled: item.desiredReminder, chooseTime: true, now: now)
        XCTAssertEqual(edit.time, item.desiredReminder)
        edit.time = now.addingTimeInterval(45)
        // Opening the sheet, choosing a clock and dismissing do not write either store.
        XCTAssertEqual(item.draft.rule, .atDue)
        correct = await checkPending(draft.due.date)
        XCTAssertTrue(correct)
        draft = try edit.applied(to: draft, now: now)
        try store.update(item, with: draft)
        correct = await checkPending(draft.customTime)
        XCTAssertTrue(correct)
        try store.toggle(item)
        correct = await checkPending(nil)
        XCTAssertTrue(correct)
        try store.toggle(item)
        correct = await checkPending(draft.customTime)
        XCTAssertTrue(correct)
        draft.customTime = Date().addingTimeInterval(4)
        try store.update(item, with: draft)
        correct = await checkPending(draft.customTime)
        XCTAssertTrue(correct)
        var delivered = false
        for _ in 0..<50 {
            if await center.deliveredNotifications().contains(where: { $0.request.identifier == id }) { delivered = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(delivered, "短间隔系统通知应进入已投递列表")
        draft.customTime = Date().addingTimeInterval(60)
        try store.update(item, with: draft)
        correct = await checkPending(draft.customTime)
        XCTAssertTrue(correct)
        try store.remove([item])
        correct = await checkPending(nil)
        XCTAssertTrue(correct)
    }

    @MainActor func testCreateDiskBenchmarkFixture() throws {
        let folder = URL.documentsDirectory.appending(path: "BenchmarkFixture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: UUID().uuidString + ".store")
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        let container = try LocalDatabase.open(configuration: config)
        let context = ModelContext(container)
        for index in 0..<1000 {
            var draft = Draft(title: "基准待办 " + String(index + 1), notes: "性能样本备注")
            draft.due = Due(kind: index.isMultiple(of: 3) ? .allDay : .timed, date: Date().addingTimeInterval(Double(index + 1) * 3600), zone: zone.identifier)
            draft.rule = .off
            let item = Item(draft)
            if index >= 200 { item.toggle() }
            context.insert(item)
        }
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Item>()), 1000)
        print("BENCHMARK_FIXTURE " + url.lastPathComponent)
    }
}

private final class TestCenter: ReminderCenter {
    var status: UNAuthorizationStatus = .denied
    var fail = false
    var requests = [String: UNNotificationRequest]()
    func permission() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { status == .authorized }
    func pendingNotificationRequests() async -> [UNNotificationRequest] { Array(requests.values) }
    func add(_ request: UNNotificationRequest) async throws {
        if fail { throw CocoaError(.fileWriteUnknown) }
        requests[request.identifier] = request
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for id in identifiers { requests.removeValue(forKey: id) }
    }
}

extension TaskTests {
    @MainActor func testDeniedFailureRecoveryAndNotificationCapacity() async throws {
        let center = TestCenter()
        let memory = try makeStore()
        let store = try TaskStore(memory.context.container, center: center)
        let drafts = (1...65).map { offset in
            Draft(title: "容量测试 " + String(offset), due: Due(kind: .timed, date: Date().addingTimeInterval(Double(offset) * 86400 + 3600), zone: zone.identifier))
        }
        let items = try store.insert(drafts)
        func settle(_ condition: () -> Bool) async {
            for _ in 0..<100 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(condition())
        }
        await settle { items.allSatisfy { $0.reminderStatus == "通知未开启" } }
        XCTAssertTrue(items.allSatisfy { $0.reminderIssue() == .denied })
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Item>()), 65)
        center.status = .authorized
        center.fail = true
        store.refresh()
        await settle { items.prefix(64).allSatisfy { $0.reminderIssue() == .pending } && items.last?.reminderIssue() == .full }
        center.fail = false
        store.refresh()
        await settle { items.prefix(64).allSatisfy { $0.reminderStatus == "已安排" } }
        XCTAssertEqual(center.requests.count, 64)
        XCTAssertEqual(items.last?.reminderIssue(), .full)
        try store.toggle(items[0])
        await settle { items.last?.reminderStatus == "已安排" }
        XCTAssertEqual(center.requests.count, 64)
        XCTAssertNil(center.requests["saywhen." + items[0].id.uuidString])
        XCTAssertNil(items[0].reminderIssue())
        XCTAssertNil(items.last?.reminderIssue())
    }
}

extension TaskTests {
    func testDatesAndClockPhrasingFromRecordings() throws {
        let parser = MandarinParser(now: date("2026-11-20T02:00:00Z"), zone: zone)
        let clear = [
            ("提醒大家，明天早上9:20吃饭", "2026-11-21T01:20:00Z"),
            ("五分钟后给家里打电话", "2026-11-20T02:05:00Z"),
            ("半小时后出发", "2026-11-20T02:30:00Z"),
            ("明天早上差五分九点开会", "2026-11-21T00:55:00Z"),
            ("明天早上九点过五分去公司", "2026-11-21T01:05:00Z"),
            ("十一月二十五日，星期三下午三点复诊", "2026-11-25T07:00:00Z")
        ]
        for (input, expected) in clear {
            let draft = try XCTUnwrap(MandarinParser.directDraft(from: parser.parse(input)), input)
            XCTAssertEqual(draft.due.date, date(expected), input)
            XCTAssertEqual(draft.due.kind, .timed, input)
        }
        for input in ["10月31日星期六下午14:00开会", "明天早上十点九点十分郊游",
                      "明天早上10:00 9:10郊游", "明天下午三点五分钟后开会",
                      "截至八月二十五日下午三时", "每天九点提醒我开会"] {
            XCTAssertNil(MandarinParser.directDraft(from: parser.parse(input)), input)
        }
    }
}

extension TaskTests {
    func testSpokenNotificationClockAndDeadlineHaveDifferentRules() throws {
        let friday = date("2026-11-20T02:00:00Z")
        let parser = MandarinParser(now: friday, zone: zone)
        let cases: [(String, String, ReminderRule, String)] = [
            ("下周一早上九点提醒我交房租", "交房租", .atDue, "2026-11-23T01:00:00Z"),
            ("提醒我在下周一上午9:00交房租", "交房租", .atDue, "2026-11-23T01:00:00Z"),
            ("请在下周一早上九点提醒我交房租", "交房租", .atDue, "2026-11-23T01:00:00Z"),
            ("下周一早上九点房租到期", "房租到期", .followDefault, "2026-11-22T12:00:00Z"),
            ("房租下周一到期", "房租到期", .followDefault, "2026-11-22T12:00:00Z"),
            ("下周一早上九点提醒我交房租，提前两小时提醒", "交房租", .lead, "2026-11-22T23:00:00Z"),
            ("下周一上午九点交房租，提前两小时提醒我", "交房租", .lead, "2026-11-22T23:00:00Z"),
            ("下周一九点提醒我交房租，提前两小时", "交房租", .lead, "2026-11-22T23:00:00Z"),
            ("交房租，下周一早上九点提醒我", "交房租", .atDue, "2026-11-23T01:00:00Z"),
            ("房租下周一到期，周日九点提醒我", "房租到期", .custom, "2026-11-22T01:00:00Z"),
            ("下周一九点记得提醒我交房租", "交房租", .atDue, "2026-11-23T01:00:00Z"),
            ("设定明天早上八点闹钟", "设定闹钟", .atDue, "2026-11-21T00:00:00Z"),
            ("下周一上午九点提醒我妈吃药", "提醒我妈吃药", .followDefault, "2026-11-22T12:00:00Z"),
            ("下周一早上九点付账，备注提醒我问小陈", "付账", .followDefault, "2026-11-22T12:00:00Z"),
            ("提醒我明早九点复诊", "复诊", .atDue, "2026-11-21T01:00:00Z")
        ]
        for (text, title, rule, notification) in cases {
            let draft = try XCTUnwrap(MandarinParser.directDraft(from: parser.parse(text)), text)
            XCTAssertEqual(draft.title, title, text)
            XCTAssertEqual(draft.rule, rule, text)
            XCTAssertEqual(draft.nextReminder(after: friday), date(notification), text)
        }
    }

    func testReviewKeepsTheSpokenDayAndRequiresAChoice() throws {
        let now = date("2026-11-20T02:00:00Z")
        let parser = MandarinParser(now: now, zone: zone)
        for (text, label, day, action) in [
            ("提醒我明天晚上聚会，备注带上礼物", "明天晚上", 21, "聚会"),
            ("明天下午去医院复诊", "明天下午", 21, "去医院复诊"),
            ("大后天早上去机场", "大后天早上", 23, "去机场"),
            ("下周一提醒我交房租", "下周一", 23, "交房租")
        ] {
            let rows = parser.parse(text)
            var timed = try XCTUnwrap(rows.first)
            XCTAssertNil(MandarinParser.directDraft(from: rows))
            XCTAssertTrue(timed.question?.contains(label) == true)
            XCTAssertEqual(timed.draft.title, action)
            XCTAssertTrue(timed.candidates.isEmpty)
            XCTAssertEqual(timed.draft.due.kind, .allDay)
            XCTAssertEqual(timed.draft.due.calendar.component(.day, from: try XCTUnwrap(timed.missingTime?.day)), day)
            var allDay = timed
            allDay.resolveTime(nil)
            XCTAssertEqual(allDay.draft.due.kind, .allDay)
            XCTAssertEqual(allDay.draft.due.calendar.component(.day, from: allDay.draft.due.date), day)
            XCTAssertEqual(allDay.draft.rule, .off)
            XCTAssertNil(allDay.draft.nextReminder(after: now))
            XCTAssertNil(allDay.question)
            // An hour picker can return a different reference date. Only its hour/minute should be taken.
            timed.resolveTime(date("2027-03-01T11:15:00Z"))
            let due = timed.draft.due
            XCTAssertEqual(due.kind, .timed)
            let parts = due.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due.date)
            XCTAssertEqual(parts, DateComponents(year: 2026, month: 11, day: day, hour: 19, minute: 15))
            XCTAssertEqual(timed.draft.nextReminder(after: now), due.date)
            XCTAssertNil(timed.missingTime)
            if text.contains("备注") { XCTAssertEqual(timed.draft.notes, "带上礼物") }
        }
        let ambiguous = parser.parse("明天或者后天下午去医院")[0]
        XCTAssertNil(ambiguous.missingTime)
        XCTAssertEqual(ambiguous.draft.due.kind, .none)
        let condition = "北京天气好时提醒我去锻炼"
        let conditional = parser.parse(condition)
        XCTAssertNil(MandarinParser.directDraft(from: conditional))
        XCTAssertNil(conditional[0].missingTime)
        XCTAssertEqual(conditional[0].draft.title, condition)
        XCTAssertEqual(conditional[0].draft.due.kind, .none)
    }

    @MainActor func testReminderEditIsTransactionalAndAnExistingRuleSurvivesReload() throws {
        let now = date("2026-11-20T02:00:00Z")
        var draft = Draft(title: "赶车", notes: "一号站台",
                          due: Due(kind: .timed, date: date("2026-11-23T01:00:00Z"), zone: zone.identifier), rule: .previousDay)
        let store = try makeStore()
        let item = Item(draft, now: now)
        store.context.insert(item)
        try store.commit()
        let reloaded = try XCTUnwrap(try TaskStore(store.context.container).item(id: item.id))
        XCTAssertEqual(reloaded.draft.rule, .previousDay)
        let original = try XCTUnwrap(item.desiredReminder)
        var edit = ReminderEdit(draft: draft, scheduled: original, chooseTime: true, now: now)
        XCTAssertEqual(edit.time, original)
        edit.time = now
        XCTAssertThrowsError(try edit.applied(to: draft, now: now))
        XCTAssertEqual(item.desiredReminder, original)
        edit.time = draft.due.date.addingTimeInterval(3600)
        XCTAssertTrue(edit.isLate(for: draft.due))
        let confirmed = try edit.applied(to: draft, now: now)
        XCTAssertEqual(confirmed.nextReminder(after: draft.due.date), edit.time)
        XCTAssertEqual(confirmed.notes, draft.notes)
        XCTAssertEqual(draft.rule, .previousDay)
        draft.rule = .atDue
        item.apply(draft, now: now)
        try store.commit()
        let readBack = try XCTUnwrap(try TaskStore(store.context.container).item(id: item.id))
        XCTAssertEqual(readBack.draft.rule, .atDue)
        XCTAssertEqual(readBack.desiredReminder, draft.due.date)
        var retitled = readBack.draft
        retitled.title = "赶火车"
        item.apply(retitled, now: now)
        XCTAssertEqual(item.notes, "一号站台")
        XCTAssertEqual(item.desiredReminder, draft.due.date)
    }
}

extension TaskTests {
    @MainActor func testOnlyUnscheduledRemindersRecoverWhenTheFirstClockHasPassed() async throws {
        let now = Date()
        let early = now.addingTimeInterval(-172800)
        let center = TestCenter()
        center.status = .authorized
        let store = try TaskStore(makeStore().context.container, center: center)
        let due = Due(kind: .timed, date: now.addingTimeInterval(3600), zone: zone.identifier)
        let missed = Item(Draft(title: "之前没有名额", due: due), now: early)
        let delivered = Item(Draft(title: "之前已排入系统", due: due), now: early)
        missed.reminderStatus = "提醒名额已满"
        delivered.reminderStatus = "已安排"
        let previousClock = delivered.desiredReminder
        store.context.insert(missed)
        store.context.insert(delivered)
        try store.commit()
        store.refresh()
        let requestID = "saywhen." + missed.id.uuidString
        for _ in 0..<60 {
            if center.requests[requestID] != nil && missed.reminderStatus == "已安排" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(center.requests[requestID])
        XCTAssertEqual(missed.desiredReminder, due.normalized.date)
        XCTAssertNil(missed.reminderIssue())
        XCTAssertNil(center.requests["saywhen." + delivered.id.uuidString])
        XCTAssertEqual(delivered.desiredReminder, previousClock)
        XCTAssertNil(delivered.reminderIssue())

        let today = Due(kind: .allDay, date: now, zone: zone.identifier)
        var plain = Draft(title: "全天事项", due: today)
        XCTAssertEqual(Item(plain, now: now).reminderIssue(at: now), .needsTime)
        plain.rule = .off
        XCTAssertNil(Item(plain, now: now).reminderIssue(at: now))
    }

    @MainActor func testCorrectedTitleReplacesNotificationTextOnTheSameItem() async throws {
        let center = TestCenter()
        center.status = .authorized
        let store = try TaskStore(makeStore().context.container, center: center)
        let due = Due(kind: .timed, date: Date().addingTimeInterval(172800), zone: zone.identifier)
        let item = try XCTUnwrap(store.insert([Draft(title: "加油", notes: "带上水", due: due, rule: .atDue)]).first)
        let originalID = item.id
        let slot = try XCTUnwrap(item.desiredReminder)
        let requestID = "saywhen." + originalID.uuidString
        func waitForTitle(_ title: String) async throws {
            for _ in 0..<80 {
                if center.requests[requestID]?.content.title == title && item.reminderStatus == "已安排" { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("未更新同一条通知的标题")
        }
        try await waitForTitle("加油")
        var changed = item.draft
        changed.title = "郊游"
        try store.update(item, with: changed)
        try await waitForTitle("郊游")
        let stored = try XCTUnwrap(try TaskStore(store.context.container, center: center).item(id: originalID))
        XCTAssertEqual(stored.title, "郊游")
        XCTAssertEqual(stored.notes, "带上水")
        XCTAssertEqual(stored.time, due.normalized.date)
        XCTAssertEqual(stored.desiredReminder, slot)
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(try store.context.fetchCount(FetchDescriptor<Item>()), 1)
    }
}

extension TaskTests {
    func testMorningReminderSeparatesClockCommandAndAction() throws {
        let morning = date("2026-11-21T17:11:00Z") // 01:11 on Sunday in Shanghai
        let parser = MandarinParser(now: morning, zone: zone)
        for input in ["今天早晨10点提醒我，我告诉老板CVPR邮件的事情",
                      "早晨十点提醒我，我告诉老板 CVPR 邮件的事情",
                      "清晨，10:00提醒我，我需要告诉老板CVPR邮件的事情"] {
            let draft = try XCTUnwrap(MandarinParser.directDraft(from: parser.parse(input)), input)
            XCTAssertEqual(draft.title, "告诉老板 CVPR 邮件的事情", input)
            XCTAssertEqual(draft.due.date, date("2026-11-22T02:00:00Z"))
            XCTAssertEqual(draft.nextReminder(after: morning, defaultAdvance: .minutes(15)), draft.due.date)
        }
        let later = MandarinParser(now: date("2026-11-22T06:00:00Z"), zone: zone)
        XCTAssertEqual(MandarinParser.directDraft(from: later.parse("早晨十点提醒我发邮件"))?.due.date, date("2026-11-23T02:00:00Z"))
        XCTAssertNil(MandarinParser.directDraft(from: later.parse("十点开会")))
        let people = try XCTUnwrap(MandarinParser.directDraft(from: parser.parse("明天早晨十点提醒我，我和小陈告诉老板CVPR结果，备注不要改 CVPR 2027")))
        XCTAssertEqual(people.title, "我和小陈告诉老板 CVPR 结果")
        XCTAssertEqual(people.notes, "不要改 CVPR 2027")
        XCTAssertEqual(MandarinParser.directDraft(from: parser.parse("明天早晨十点提醒我妈吃药"))?.title, "提醒我妈吃药")
        XCTAssertEqual(ActionTitle.suggestion(for: "早晨提醒我，我告诉老板CVPR邮件的事情"), "告诉老板 CVPR 邮件的事情")
        XCTAssertNil(ActionTitle.suggestion(for: "早晨提醒我妈吃药"))
        XCTAssertNil(ActionTitle.suggestion(for: "告诉老板 CVPR 邮件的事情"))
    }

    func testDefaultEveningAndArbitraryOffsetsInTaskZone() {
        let local = Due(kind: .timed, date: date("2027-01-01T02:00:00Z"), zone: zone.identifier)
        var d = Draft(title: "交报告", due: local)
        XCTAssertEqual(d.nextReminder(after: .distantPast), date("2026-12-31T12:00:00Z"))
        XCTAssertEqual(d.nextReminder(after: .distantPast, defaultAdvance: .minutes(120)), date("2027-01-01T00:00:00Z"))
        XCTAssertEqual(d.nextReminder(after: .distantPast, defaultAdvance: .minutes(15)), date("2027-01-01T01:45:00Z"))
        d.due.kind = .allDay
        XCTAssertEqual(d.nextReminder(after: .distantPast, defaultAdvance: .minutes(15)), date("2026-12-31T15:45:00Z"))
        d.due = Due(kind: .timed, date: date("2027-03-14T19:00:00Z"), zone: "America/New_York")
        XCTAssertEqual(d.nextReminder(after: .distantPast), date("2027-03-14T01:00:00Z"))
        d.rule = .previousEvening
        XCTAssertEqual(d.nextReminder(after: .distantPast, defaultAdvance: .minutes(75)), date("2027-03-14T01:00:00Z"))
        XCTAssertEqual(d.nextReminder(after: date("2027-03-14T10:00:00Z")), d.due.date)
        d.rule = .off
        XCTAssertNil(d.nextReminder(after: .distantPast, defaultAdvance: .minutes(120)))
    }

    @MainActor func testGlobalChangeReschedulesFollowersAndPreservesOverrides() async throws {
        let center = TestCenter(); center.status = .authorized
        let container = try LocalDatabase.open(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try TaskStore(container, center: center)
        let clock = Due(kind: .timed, date: Date().addingTimeInterval(4 * 86400), zone: zone.identifier)
        let drafts = [Draft(title: "跟随", due: clock), Draft(title: "单条", due: clock, rule: .lead, leadMinutes: 15),
                      Draft(title: "明说钟点", due: clock, rule: .atDue), Draft(title: "旧规则", due: clock, rule: .previousDay),
                      Draft(title: "关闭", due: clock, rule: .off), Draft(title: "完成", due: clock)]
        let items = try store.insert(drafts)
        try store.toggle(items[5])
        let prior = items.map(\.desiredReminder)
        try store.savePreferences(AppPreferences(advance: .minutes(120), language: .mandarin, vocabulary: "CVPR\nMyProject"))
        let mustRing = clock.normalized.date.addingTimeInterval(-7200)
        XCTAssertEqual(items[0].desiredReminder, mustRing)
        XCTAssertEqual(Array(items.map(\.desiredReminder).dropFirst()), Array(prior.dropFirst()))
        let key = "saywhen." + items[0].id.uuidString
        for _ in 0..<80 {
            if let req = center.requests[key], (req.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() == mustRing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual((center.requests[key]?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate(), mustRing)
        XCTAssertEqual(center.requests.count, 4)
        let reopened = try TaskStore(container, center: center)
        XCTAssertEqual(reopened.preferences.advance, .minutes(120))
        XCTAssertEqual(reopened.preferences.vocabulary, "CVPR\nMyProject")
        var edit = ReminderEdit(draft: items[0].draft, scheduled: items[0].desiredReminder)
        edit.rule = .lead; edit.leadMinutes = 15
        try store.update(items[0], with: edit.applied(to: items[0].draft))
        try store.savePreferences(AppPreferences(advance: .minutes(90)))
        XCTAssertEqual(items[0].desiredReminder, clock.normalized.date.addingTimeInterval(-900))
        try store.toggle(items[5])
        XCTAssertEqual(items[5].desiredReminder, clock.normalized.date.addingTimeInterval(-5400))
        var follow = items[0].draft; follow.rule = .followDefault
        try store.update(items[0], with: follow)
        XCTAssertEqual(items[0].desiredReminder, clock.normalized.date.addingTimeInterval(-5400))
        XCTAssertThrowsError(try store.savePreferences(AppPreferences(advance: .minutes(-1))))
        XCTAssertEqual(store.preferences.advance, .minutes(90))
    }

    @MainActor func testUpgradeFromVersionOnePreservesTaskAndReminder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "default.store")
        let clock = Due(kind: .timed, date: Date().addingTimeInterval(5 * 86400), zone: zone.identifier)
        let id: UUID = try autoreleasepool {
            let oldSchema = Schema(versionedSchema: SchemaV1.self)
            let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(schema: oldSchema, url: file))
            let context = ModelContext(old)
            let item = Item(Draft(title: "早晨提醒我，我告诉同事邮件的事情", notes: "原有备注", due: clock, rule: .previousDay))
            item.calendarLink = Data([1,2,3])
            context.insert(item); try context.save()
            return item.id
        }
        let current = try LocalDatabase.open(configuration: ModelConfiguration(url: file, cloudKitDatabase: .none))
        let store = try TaskStore(current, center: TestCenter())
        let old = try XCTUnwrap(store.item(id: id))
        let before = old.desiredReminder
        XCTAssertEqual(old.draft.rule, .previousDay)
        XCTAssertEqual(old.title, "早晨提醒我，我告诉同事邮件的事情")
        XCTAssertEqual(old.notes, "原有备注")
        XCTAssertEqual(old.calendarLink, Data([1,2,3]))
        XCTAssertEqual(store.preferences.advance, .previousEvening)
        try store.savePreferences(AppPreferences(advance: .minutes(15)))
        XCTAssertEqual(old.desiredReminder, before)
        XCTAssertEqual(try store.item(id: id)?.id, id)
    }

    func testSpeechHintsPreserveOnlyMatchingSpellings() throws {
        let words = SpeechVocabulary(personal: "OpenAI\nProjectX\ncvpr\nOpenAI")
        XCTAssertEqual(words.terms.filter { $0 == "OpenAI" }.count, 1)
        XCTAssertEqual(words.display("交 C V P R 的 P.D.F. 给 Git Hub"), "交 cvpr 的 PDF. 给 GitHub")
        XCTAssertEqual(words.display("发 CPR 急救文档，不要把 get 改掉"), "发 CPR 急救文档，不要把 get 改掉")
        XCTAssertEqual(words.display("联系 Project X 的 Alice"), "联系 ProjectX 的 Alice")
        XCTAssertThrowsError(try AppPreferences(vocabulary: String(repeating:"A",count:65)).validated())
    }
}
