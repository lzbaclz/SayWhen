import Foundation
import EventKit

struct EventTime: Codable, Equatable {
    var start: Date
    var end: Date
    var allDay: Bool
    var zone: String?

    static let utc = TimeZone(secondsFromGMT: 0)!

    static func civilDate(_ date: Date, from source: TimeZone, to target: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = source
        let day = cal.dateComponents([.year, .month, .day], from: date)
        cal.timeZone = target
        return cal.date(from: day)!
    }
}

struct EventFields: Codable, Equatable {
    var title: String
    var notes: String
    var time: EventTime

    init(_ item: Item) {
        title = item.title
        notes = item.notes
        let due = item.draft.due.normalized
        let allDay = due.kind == .allDay
        let start = due.date
        let end = allDay ? due.calendar.date(byAdding: .day, value: 1, to: start)! : start.addingTimeInterval(900)
        if allDay {
            time = EventTime(start: EventTime.civilDate(start, from: due.calendar.timeZone, to: EventTime.utc),
                             end: EventTime.civilDate(end, from: due.calendar.timeZone, to: EventTime.utc), allDay: true, zone: nil)
        } else { time = EventTime(start: start, end: end, allDay: false, zone: due.zone) }
    }

    init(_ event: EKEvent) {
        title = event.title ?? ""
        notes = event.notes ?? ""
        if event.isAllDay {
            let zone = event.timeZone ?? .current
            time = EventTime(start: EventTime.civilDate(event.startDate, from: zone, to: EventTime.utc),
                             end: EventTime.civilDate(event.endDate, from: zone, to: EventTime.utc), allDay: true, zone: nil)
        } else { time = EventTime(start: event.startDate, end: event.endDate, allDay: false, zone: event.timeZone?.identifier) }
    }
}

struct CalendarReceipt: Codable {
    var calendarID: String
    var calendarName: String
    var eventID: String?
    var local: EventFields?
    var remote: EventFields?
    var syncedAt: Date?
    var intent: EventFields?
    var revision: Int
}

extension Item {
    var receipt: CalendarReceipt? {
        calendarLink.flatMap { try? JSONDecoder().decode(CalendarReceipt.self, from: $0) }
    }
}

enum SyncFailure: LocalizedError {
    case unavailable, lost, denied, undated
    case conflict([String], EventFields)
    var errorDescription: String? {
        switch self {
        case .denied: return "待办已保存，日历未更新。请在设置中允许完全访问日历。"
        case .unavailable: return "待办已保存，目标日历不可写。"
        case .undated: return "请先补选到期日期。"
        case .lost: return "无法确认原日程。请在苹果日历中核对，再决定是否重新添加。"
        case .conflict(let changes, _): return changes.joined(separator: "\n\n")
        }
    }
}

@MainActor final class CalendarSync {
    lazy var events = EKEventStore()
    func calendars() async throws -> [EKCalendar] {
        guard try await events.requestFullAccessToEvents() else { throw SyncFailure.denied }
        let list = events.calendars(for: .event).filter(\.allowsContentModifications)
        guard !list.isEmpty else { throw SyncFailure.unavailable }
        return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // Runs synchronously on the main actor after permission/selection. Durable intent precedes EventKit commit.
    func write(_ item: Item, to target: EKCalendar, in store: TaskStore,
               replaceMissing: Bool = false, confirmedRemote: EventFields? = nil) throws {
        guard item.kind != DateKind.none.rawValue else { throw SyncFailure.undated }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw SyncFailure.denied }
        guard target.allowsContentModifications else { throw SyncFailure.unavailable }
        if replaceMissing && item.calendarLink != nil {
            // Re-check after the user returns from Calendar. A previously missing event might be visible again.
            do { try write(item, to: target, in: store, confirmedRemote: confirmedRemote); return }
            catch SyncFailure.lost { }
        }
        let marker = URL(string: "saywhen://task/" + item.id.uuidString)!
        let local = EventFields(item)
        var receipt = replaceMissing ? nil : item.receipt
        if !replaceMissing && item.calendarLink != nil && receipt == nil { throw SyncFailure.lost }
        let event: EKEvent
        if let receipt {
            guard receipt.calendarID == target.calendarIdentifier else { throw SyncFailure.lost }
            if let id = receipt.eventID, let found = events.event(withIdentifier: id),
               found.calendar.calendarIdentifier == receipt.calendarID, found.url == nil || found.url == marker {
                event = found
            } else {
                let dates = [receipt.intent?.time.start, receipt.remote?.time.start].compactMap { $0 }
                var matches = [String: EKEvent]()
                for date in dates {
                    let probe = events.predicateForEvents(withStart: date.addingTimeInterval(-172800), end: date.addingTimeInterval(172800), calendars: [target])
                    for found in events.events(matching: probe) where found.url == marker {
                        matches[found.calendarItemIdentifier] = found
                    }
                }
                guard matches.count == 1, let found = matches.values.first else { throw SyncFailure.lost }
                event = found
            }
        } else {
            event = EKEvent(eventStore: events)
            event.calendar = target
            event.url = marker
            if target.supportedEventAvailabilities.contains(.free) { event.availability = .free }
        }
        let fresh = receipt == nil
        let remote = fresh ? local : EventFields(event)
        let oldLocal = receipt?.local ?? receipt?.intent
        let oldRemote = receipt?.remote ?? receipt?.intent
        let titleChanged = fresh || local.title != oldLocal?.title
        let notesChanged = fresh || local.notes != oldLocal?.notes
        let timeChanged = fresh || local.time != oldLocal?.time
        var conflicts = [String]()
        if !fresh {
            if titleChanged && remote.title != oldRemote?.title && remote.title != local.title {
                conflicts.append("标题\n日历：\(remote.title)\n待办：\(local.title)")
            }
            if notesChanged && remote.notes != oldRemote?.notes && remote.notes != local.notes {
                conflicts.append("备注\n日历：\(remote.notes.isEmpty ? "（空）" : remote.notes)\n待办：\(local.notes.isEmpty ? "（空）" : local.notes)")
            }
            if timeChanged && remote.time != oldRemote?.time && remote.time != local.time {
                func describe(_ time: EventTime) -> String {
                    Due(kind: time.allDay ? .allDay : .timed, date: time.start, zone: time.allDay ? EventTime.utc.identifier : (time.zone ?? TimeZone.current.identifier)).label
                }
                conflicts.append("时间\n日历：\(describe(remote.time))\n待办：\(describe(local.time))")
            }
        }
        if !conflicts.isEmpty && confirmedRemote != remote { throw SyncFailure.conflict(conflicts, remote) }
        if receipt == nil {
            receipt = CalendarReceipt(calendarID: target.calendarIdentifier, calendarName: target.title, revision: item.revision)
        }
        guard var link = receipt else { throw SyncFailure.unavailable }
        link.intent = local
        link.revision = item.revision
        item.calendarLink = try JSONEncoder().encode(link)
        try store.commit()
        if titleChanged { event.title = local.title }
        if notesChanged { event.notes = local.notes.isEmpty ? nil : local.notes }
        if timeChanged {
            let time = local.time
            event.isAllDay = time.allDay
            event.timeZone = time.allDay ? nil : TimeZone(identifier: item.zone)
            event.startDate = time.allDay ? EventTime.civilDate(time.start, from: EventTime.utc, to: .current) : time.start
            event.endDate = time.allDay ? EventTime.civilDate(time.end, from: EventTime.utc, to: .current) : time.end
        }
        if titleChanged || notesChanged || timeChanged {
            try events.save(event, span: .thisEvent, commit: true)
        }
        let written = EventFields(event)
        // Keep old baselines for remote-only changes, so later local edits still detect a conflict.
        var baseline = oldRemote ?? written
        if titleChanged { baseline.title = written.title }
        if notesChanged { baseline.notes = written.notes }
        if timeChanged { baseline.time = written.time }
        link.remote = baseline
        link.local = local
        link.calendarName = target.title
        link.eventID = event.eventIdentifier
        link.syncedAt = .now
        link.intent = nil
        item.calendarLink = try JSONEncoder().encode(link)
        try store.commit()
    }
}

