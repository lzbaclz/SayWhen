import Foundation
import SwiftData

enum DateKind: String, Codable, CaseIterable { case none, allDay, timed }
enum ReminderRule: String, Codable, CaseIterable { case followDefault, previousEvening, previousDay, atDue, lead, custom, off }

enum ReminderIssue {
    case denied, pending, full, needsTime

    var label: String {
        switch self {
        case .denied: "不会提醒 · 通知未开启"
        case .pending: "提醒待安排"
        case .full: "待安排 · 提醒名额已满"
        case .needsTime: "不会提醒 · 选时间"
        }
    }
}

struct Due: Codable, Equatable {
    var kind = DateKind.none
    var date = Date()
    var zone = TimeZone.current.identifier

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        return calendar
    }

    var label: String {
        guard kind != .none else { return "无日期" }
        let includeZone = kind == .timed && zone != TimeZone.current.identifier
        return Self.format(date, zone: calendar.timeZone,
                           pattern: kind == .allDay ? "yyyy年M月d日 EEEE · 全天" : "yyyy年M月d日 EEEE HH:mm" + (includeZone ? " z" : ""))
    }

    func dayLabel(relativeTo now: Date) -> String {
        let cal = calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day
        switch days {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default:
            let pattern = cal.component(.year, from: now) == cal.component(.year, from: date) ? "M月d日 EEE" : "yyyy年M月d日"
            return Self.format(date, zone: cal.timeZone, pattern: pattern)
        }
    }

    var shortLabel: String {
        guard kind != .none else { return "无日期" }
        let day = dayLabel(relativeTo: .now)
        guard kind == .timed else { return day + " · 全天" }
        let format = zone == TimeZone.current.identifier ? "HH:mm" : "HH:mm z"
        return day + " " + Self.format(date, zone: calendar.timeZone, pattern: format)
    }

    private static let formatters: NSCache<NSString, DateFormatter> = {
        let cache = NSCache<NSString, DateFormatter>()
        cache.countLimit = 48
        return cache
    }()

    static func format(_ date: Date, zone: TimeZone, pattern: String) -> String {
        let key = (zone.identifier + "|" + pattern) as NSString
        if let existing = formatters.object(forKey: key) { return existing.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        formatters.setObject(formatter, forKey: key)
        return formatter.string(from: date)
    }

    // All-day dates are anchored to civil midnight in their original calendar.
    var normalized: Due {
        var value = self
        if kind == .allDay { value.date = calendar.startOfDay(for: date) }
        if kind == .timed {
            value.date = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        }
        return value
    }

    func reminderIsAfterDue(_ instant: Date) -> Bool {
        switch kind {
        case .none: return false
        case .timed: return instant > normalized.date
        case .allDay: return calendar.compare(instant, to: date, toGranularity: .day) == .orderedDescending
        }
    }
}

struct Draft: Equatable {
    var title = ""
    var notes = ""
    var due = Due()
    var rule = ReminderRule.followDefault
    var leadMinutes = 120
    var customTime = Date()
    var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var reminderLabel: String {
        switch rule {
        case .followDefault: "跟随全局"
        case .previousEvening: DefaultAdvance.previousEvening.label
        case .previousDay: "提前一天"
        case .atDue: "到点提醒"
        case .lead: DefaultAdvance.label(minutes: leadMinutes)
        case .custom: "自选时间"
        case .off: "仅保存"
        }
    }

    func nextReminder(after now: Date, defaultAdvance: DefaultAdvance = .previousEvening) -> Date? {
        guard due.kind != .none, rule != .off else { return nil }
        if rule == .custom { return customTime > now ? customTime : nil }
        let cal = due.calendar
        let day = cal.startOfDay(for: due.date)
        if due.kind == .allDay && day < cal.startOfDay(for: now) { return nil }
        if due.kind == .timed && due.date <= now { return nil }
        let proposed: Date?
        switch rule {
        case .off, .custom: return nil
        case .atDue: return due.kind == .timed ? due.date : nil
        case .followDefault: proposed = defaultAdvance.time(for: due)
        case .previousEvening: proposed = DefaultAdvance.previousEvening.time(for: due)
        case .lead: proposed = DefaultAdvance.minutes(leadMinutes).time(for: due)
        case .previousDay:
            let previous = cal.date(byAdding: .day, value: -1, to: due.date)
            if due.kind == .allDay {
                proposed = previous.flatMap { cal.date(bySettingHour: 20, minute: 0, second: 0, of: $0) }
            } else { proposed = previous }
        }
        if let proposed, proposed > now { return proposed }
        return due.kind == .timed ? due.date : nil
    }
}

/// The reminder sheet owns this value until the user confirms.
struct ReminderEdit {
    var rule: ReminderRule
    var time: Date
    var leadMinutes: Int

    init(draft: Draft, scheduled: Date?, chooseTime: Bool = false, now: Date = .now,
         defaultAdvance: DefaultAdvance = .previousEvening) {
        rule = chooseTime ? .custom : draft.rule
        leadMinutes = draft.leadMinutes
        if let scheduled, scheduled > now { time = scheduled }
        else if let next = draft.nextReminder(after: now, defaultAdvance: defaultAdvance) { time = next }
        else if draft.due.kind == .timed && draft.due.date > now { time = draft.due.date }
        else { time = draft.due.calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(3600) }
    }

    func isLate(for due: Due) -> Bool {
        rule == .custom && due.reminderIsAfterDue(time)
    }

    func applied(to draft: Draft, now: Date = .now) throws -> Draft {
        guard rule != .custom || time > now else { throw ReminderEditError.past }
        var result = draft
        result.rule = rule
        if rule == .custom { result.customTime = time }
        if rule == .lead { result.leadMinutes = leadMinutes }
        return result
    }
}

private enum ReminderEditError: LocalizedError {
    case past
    var errorDescription: String? { "请选择将来的提醒时刻。" }
}

enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Item.self] }
    @Model final class Item {
        @Attribute(.unique) var id: UUID
        var created: Date
        var completed: Date?
        var isDone: Bool
        var title: String
        var notes: String
        var hasNotes: Bool
        var kind: String
        var time: Date
        var zone: String
        var sortDay: String
        var sortRank: Int
        var rule: String
        var leadMinutes: Int
        var customTime: Date
        var revision: Int
        var desiredReminder: Date?
        var reminderStatus: String
        var calendarLink: Data?

        init(_ draft: Draft, now: Date = .now, defaultAdvance: DefaultAdvance = .previousEvening) {
            id = UUID()
            created = now
            isDone = false
            title = ""
            notes = ""
            hasNotes = false
            kind = DateKind.none.rawValue
            time = now
            zone = draft.due.zone
            sortDay = ""
            sortRank = 0
            rule = draft.rule.rawValue
            leadMinutes = draft.leadMinutes
            customTime = draft.customTime
            revision = 0
            reminderStatus = ""
            apply(draft, now: now, defaultAdvance: defaultAdvance)
        }

        var draft: Draft {
            Draft(title: title, notes: notes,
                  due: Due(kind: DateKind(rawValue: kind) ?? .none, date: time, zone: zone),
                  rule: ReminderRule(rawValue: rule) ?? .previousDay,
                  leadMinutes: leadMinutes, customTime: customTime)
        }

        func reminderIssue(at now: Date = .now) -> ReminderIssue? {
            guard !isDone, kind != DateKind.none.rawValue, rule != ReminderRule.off.rawValue else { return nil }
            if let desiredReminder, desiredReminder > now {
                switch reminderStatus {
                case "已安排": return nil
                case "通知未开启": return .denied
                case "提醒名额已满": return .full
                default: return .pending
                }
            }
            // A previously scheduled reminder may already have been delivered.
            guard reminderStatus != "已安排" else { return nil }
            if kind == DateKind.timed.rawValue { return time > now ? .needsTime : nil }
            let due = Due(kind: .allDay, date: time, zone: zone)
            return due.calendar.compare(time, to: now, toGranularity: .day) == .orderedAscending ? nil : .needsTime
        }

        func apply(_ new: Draft, now: Date = .now, defaultAdvance: DefaultAdvance = .previousEvening) {
            let value = new.due.normalized
            let scheduleChanged = revision == 0 || kind != value.kind.rawValue || time != value.date ||
                zone != value.zone || rule != new.rule.rawValue || leadMinutes != new.leadMinutes || customTime != new.customTime
            title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
            notes = new.notes
            hasNotes = !notes.isEmpty
            kind = value.kind.rawValue
            time = value.date
            zone = value.zone
            sortDay = value.kind == .none ? "99999999" : Due.format(time, zone: value.calendar.timeZone, pattern: "yyyyMMdd")
            sortRank = value.kind == .timed ? 1 : 0
            rule = new.rule.rawValue
            leadMinutes = new.leadMinutes
            customTime = new.customTime
            revision += 1
            if scheduleChanged { resetReminder(now: now, defaultAdvance: defaultAdvance) }
        }

        func resetReminder(now: Date = .now, defaultAdvance: DefaultAdvance = .previousEvening) {
            desiredReminder = isDone ? nil : draft.nextReminder(after: now, defaultAdvance: defaultAdvance)
            reminderStatus = desiredReminder == nil ? "" : "提醒待安排"
        }

        func toggle(defaultAdvance: DefaultAdvance = .previousEvening) {
            isDone.toggle()
            completed = isDone ? .now : nil
            revision += 1
            resetReminder(defaultAdvance: defaultAdvance)
        }
    }
}
typealias Item = SchemaV1.Item

enum MigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)] }
}
