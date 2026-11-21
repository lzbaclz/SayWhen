import Foundation

struct ParsedTask: Identifiable {
    let id = UUID()
    var draft: Draft
    var question: String?
    var candidates: [Date] = []
    var missingTime: MissingTime?

    mutating func resolveTime(_ clock: Date?) {
        guard let missingTime else { return }
        let cal = draft.due.calendar
        if let clock {
            let hm = cal.dateComponents([.hour, .minute], from: clock)
            guard let date = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: missingTime.day) else { return }
            draft.due.kind = .timed
            draft.due.date = date
            if draft.rule != .lead { draft.rule = .atDue }
        } else {
            draft.due.kind = .allDay
            draft.due.date = missingTime.day
            draft.rule = .off
        }
        self.missingTime = nil
        question = nil
    }
}

struct MissingTime {
    let day: Date
    let dayName: String
    let period: String

    func pickerStart(in calendar: Calendar) -> Date {
        let hour: Int
        switch period {
        case "凌晨": hour = 5
        case "中午": hour = 12
        case "下午": hour = 15
        case "傍晚": hour = 18
        case "晚上": hour = 20
        default: hour = 9
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
}

struct MandarinParser {
    let now: Date
    let zone: TimeZone
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = zone
        value.firstWeekday = 2
        return value
    }
    private let numbers = "[0-9零〇一二两三四五六七八九十百]+"
    private let periods = "凌晨|早晨|清晨|清早|早间|早上|上午|中午|下午|傍晚|晚上|晚间"
    private let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。；;、"))

    func parse(_ text: String) -> [ParsedTask] {
        // An explicitly introduced next item may follow an earlier item's dictated note.
        let independent = text.replacingOccurrences(of: #"[，,；;。]?\s*(?:另外一件事|还有一件事)\s*"#,
                                                    with: "\u{1E}", options: .regularExpression)
        if independent.contains("\u{1E}") {
            return independent.components(separatedBy: "\u{1E}").filter { !$0.isEmpty }.flatMap(parse)
        }
        // Notes can contain conjunctions, dates and numbers. Keep the entire suffix verbatim.
        let parts = text.components(separatedBy: "备注")
        var body = parts[0]
        let notes = parts.dropFirst().joined(separator: "备注")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:")))
        if let correction = match("(?:不对|说错了|改成)[，,、 ]*", in: body) {
            let prefix = String(body[..<correction.range.lowerBound]).trimmingCharacters(in: trim)
            let suffix = String(body[correction.range.upperBound...])
            // Discard a replaced time-only prefix. Preserve a potentially independent action.
            if parseOne(prefix).draft.title.isEmpty { body = suffix }
            else {
                return [ParsedTask(draft: Draft(title: body, notes: notes),
                                   question: "请核对改口后的事项和日期")]
            }
        }
        // Speech may insert a comma between the addressee and its single dated instruction.
        body = body.replacingOccurrences(of: #"^((?:请)?(?:提醒|叫)(?:大家|大伙儿?|我们|我|你|他|她))[，,]\s*"#,
                                         with: "$1", options: .regularExpression)
        body = body.replacingOccurrences(of: #"([日号])[，,]\s*(?=(?:星期|周|礼拜)[一二三四五六日天])"#,
                                         with: "$1", options: .regularExpression)
        if var task = taskWithTrailingReminder(in: body) {
            task.draft.notes = notes
            return [task]
        }
        let boundary = #"[，,；;。]\s*(?:然后|再|另外|还有)?\s*(?=(?:大?后天|明天|今天|下周|本周|这周|周[一二三四五六日天]|星期|\d{1,2}月))|[；;]|\s*(?:另外(?:一件事)?|还有一件事|然后再|然后(?=去|买|交|寄|接|给|明天|后天|下周))\s*"#
        let separated = body.replacingOccurrences(of: boundary, with: "\u{1F}", options: .regularExpression)
        let clauses = separated.components(separatedBy: "\u{1F}").filter { !$0.trimmingCharacters(in: trim).isEmpty }
        var result = clauses.map(parseOne)
        if result.isEmpty { result = [parseOne("")] }
        result[result.count - 1].draft.notes = notes
        return result
    }

    static func directDraft(from rows: [ParsedTask]) -> Draft? {
        guard rows.count == 1, let first = rows.first, first.question == nil, first.draft.valid else { return nil }
        return first.draft
    }

    // A trailing clock with no action of its own belongs to the preceding single task.
    // "交房租，下周一九点提醒我" differs from "买牛奶，下周一九点提醒我交房租".
    private func taskWithTrailingReminder(in body: String) -> ParsedTask? {
        guard let split = body.lastIndex(where: { "，,；;。".contains($0) }) else { return nil }
        let tail = String(body[body.index(after: split)...])
        guard tail.contains("提醒我") || tail.contains("通知我") else { return nil }
        let reminder = parseOne(tail).draft
        guard reminder.rule == .atDue, reminder.due.kind == .timed, reminder.title.isEmpty else { return nil }
        let tasks = parse(String(body[..<split]))
        guard tasks.count == 1, var task = tasks.first, task.question == nil, task.draft.valid else { return nil }
        if task.draft.rule == .lead { return task }
        if task.draft.due.kind == .none || task.draft.due == reminder.due {
            task.draft.due = reminder.due
            task.draft.rule = .atDue
        } else {
            task.draft.rule = .custom
            task.draft.customTime = reminder.due.date
            if task.draft.due.reminderIsAfterDue(reminder.due.date) {
                task.question = "提醒晚于到期时间，要按这个时间保存吗？"
            }
        }
        return task
    }

    private func parseOne(_ raw: String) -> ParsedTask {
        var body = raw.trimmingCharacters(in: trim)
        for prefix in ["帮我记一下", "记一下"] where body.hasPrefix(prefix) {
            body.removeFirst(prefix.count)
        }
        var draft = Draft()
        draft.due.zone = zone.identifier
        draft.due.date = calendar.startOfDay(for: now)
        var question: String?
        var choices: [Date] = []
        let leadPattern = "提前(半|" + numbers + ")(?:个)?(小时|分钟|天)(?:提醒(?:我)?|(?=[，,。；;！!\\s]*$))"
        if let lead = match(leadPattern, in: body) {
            let unit = ["小时": 60, "分钟": 1, "天": 1440][lead.groups[1]]!
            let minutes = lead.groups[0] == "半" && unit > 1 ? unit / 2 : number(lead.groups[0]).map { $0 * unit }
            if let minutes {
                draft.leadMinutes = minutes
                draft.rule = .lead
                body.removeSubrange(lead.range)
            }
        }
        body = body.trimmingCharacters(in: trim)
        // A condition can precede the request ("天气好时提醒我去锻炼").
        // Keep that wording, even when the request cannot be stripped as a prefix.
        let mentionsReminder = match(personalRequest, in: body) != nil
        var personalReminder = stripReminderRequest(from: &body)
        body = body.replacingOccurrences(of: #"明(?:早晨|早上?|晨)"#, with: "明天早上", options: .regularExpression)
            .replacingOccurrences(of: #"明晚上?"#, with: "明天晚上", options: .regularExpression)
            .replacingOccurrences(of: #"今晚上?"#, with: "今天晚上", options: .regularExpression)
            .replacingOccurrences(of: #"今(?:早晨|早上?|晨)"#, with: "今天早上", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:请)?在(?=大?后天|明天|今天|(?:下下?|这|本)?(?:周|星期|礼拜)|[0-9零〇一二两三四五六七八九十]+[月年点])"#,
                                  with: "", options: .regularExpression)
        let (day, conflict) = extractDay(from: &body)
        guard !conflict, extractTime(from: &body, day: day, allowNextClock: mentionsReminder, due: &draft.due) else {
            draft.title = raw
            draft.due.kind = .none
            if personalReminder && draft.rule != .lead { draft.rule = .atDue }
            return ParsedTask(draft: draft, question: "请核对是哪天、几点")
        }
        // "提醒我周一九点…" and "周一九点提醒我…" refer to the notification clock.
        // An explicit lead was consumed first and always takes precedence.
        if stripReminderRequest(from: &body) { personalReminder = true }
        if match(#"^(?:设定|设置|设|定)(?:一个|个)?的?闹钟$"#, in: body) != nil {
            personalReminder = true
        }
        if personalReminder && draft.rule != .lead { draft.rule = .atDue }
        let ambiguous = "每(?:天|日|周|星期|月|年|隔)|之前|以前|周末|下星期(?![一二三四五六日天])|找个时间|有空|过几天|下个月|月底|月初|月末|周左右|下旬|中旬|上旬|节前|届时|周[一二三四五六日天]到|[0-9一二两三四五六七八九十]+号|过一阵|这几天|下周|下礼拜|稍后|周一|周二|周三|周四|周五|周六|周日|明天|后天|下班|提前|小时后|分钟后|天后|" + periods
        if let day, draft.due.kind == .allDay {
            var title = body
            let period = match(periods, in: title)
            if let period { title.removeSubrange(period.range) }
            if stripReminderRequest(from: &title) { personalReminder = true }
            if (period != nil || personalReminder || mentionsReminder || draft.rule == .lead), match(ambiguous, in: title) == nil {
                let dayName = match(relativeDayPattern, in: raw)?.full
                    ?? match(weekdayPattern, in: raw)?.full
                    ?? draft.due.dayLabel(relativeTo: now)
                let part = period?.full ?? ""
                let ask = draft.rule == .lead ? "几点到期？" : "几点提醒？"
                draft.title = ActionTitle.clean(title, personalCommand: personalReminder)
                return ParsedTask(draft: draft, question: dayName + part + ask,
                                  missingTime: MissingTime(day: day, dayName: dayName, period: part))
            }
        }
        if match(ambiguous, in: body) != nil {
            if let day {
                choices = [calendar.date(byAdding: .day, value: -1, to: day), day].compactMap { $0 }
            }
            question = "这件事安排在哪天？"
            draft.due.kind = .none
            // Keep unresolved wording visible until the user selects a date.
            body = raw
        }
        if (personalReminder || mentionsReminder || raw.contains("找个时间")) && draft.due.kind == .none {
            question = "哪天提醒你？也可以先存为无日期。"
            if mentionsReminder && draft.rule != .lead { draft.rule = .atDue }
        }
        if draft.rule == .lead && draft.due.kind != .timed { question = "请核对到期与提前提醒的时间" }
        draft.title = ActionTitle.clean(body, personalCommand: question == nil && personalReminder)
        if question == nil, match("[，,。].*(?:去|买|交|寄|接|打电话|发送)", in: draft.title) != nil {
            question = "请核对是否包含多件事"
        }
        if draft.title.isEmpty || ["截至","截止","截止到","截至到"].contains(draft.title) {
            question = "补一个待办标题"
        }
        return ParsedTask(draft: draft, question: question, candidates: choices)
    }

    private let personalRequest = #"(?:提醒|通知|叫)我(?!们|的|[爸妈哥姐弟妹]|家人|朋友|同事|儿子|女儿)"#

    private func stripReminderRequest(from body: inout String) -> Bool {
        body = body.trimmingCharacters(in: trim)
        // Keep the recipient in actions such as "提醒我妈吃药" or "提醒我的同事".
        if let request = match("^(?:(?:到点|到时|一定要|务必|记得|请你?|麻烦你?|在|要)\\s*)*" + personalRequest + "(?:一下)?[，,、 ]*", in: body) {
            body.removeSubrange(request.range)
            return true
        }
        if let request = match("[，,、 ]*(?:到点|到时)?" + personalRequest + "(?:一下)?$", in: body) {
            body.removeSubrange(request.range)
            return true
        }
        return false
    }

    private var explicitDayPattern: String { "(?:(" + numbers + ")年)?(" + numbers + ")月(" + numbers + ")(?:日|号)?" }
    private let relativeDayPattern = "大后天|后天|明天|今天|昨天"
    private let weekdayPattern = "(下下|上上|下|上|本|这)?(?:周|星期|礼拜)([一二三四五六日天])"

    private func extractDay(from body: inout String) -> (date: Date?, conflict: Bool) {
        let today = calendar.startOfDay(for: now)
        var result: Date?
        if let hit = match(explicitDayPattern, in: body) {
            let year = number(hit.groups[0]) ?? calendar.component(.year, from: today)
            guard let month = number(hit.groups[1]), let day = number(hit.groups[2]) else { return (nil, true) }
            func create(_ year: Int) -> Date? {
                guard let value = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                      calendar.component(.month, from: value) == month, calendar.component(.day, from: value) == day else { return nil }
                return value
            }
            guard let date = create(year) else { return (nil, true) }
            result = hit.groups[0].isEmpty && date < today ? create(year + 1) : date
            guard result != nil else { return (nil, true) }
            body.removeSubrange(hit.range)
        }
        if let hit = match(relativeDayPattern, in: body) {
            let relative = ["今天": 0, "明天": 1, "后天": 2, "大后天": 3, "昨天": -1]
            let date = calendar.date(byAdding: .day, value: relative[hit.full]!, to: today)
            if let result, result != date { return (nil, true) }
            result = date
            body.removeSubrange(hit.range)
        }
        if let hit = match(weekdayPattern, in: body) {
            let target = ["一","二","三","四","五","六","日"].firstIndex(of: hit.groups[1]) ?? 6
            let week = hit.groups[0]
            let weekday = (calendar.component(.weekday, from: today) + 5) % 7
            let weeks = ["下下": 2, "下": 1, "上": -1, "上上": -2][week] ?? 0
            var offset = target - weekday + 7 * weeks
            if week.isEmpty && offset < 0 { offset += 7 }
            let date = calendar.date(byAdding: .day, value: offset, to: today)
            if let result {
                let actual = (calendar.component(.weekday, from: result) + 5) % 7
                if actual != target || (!week.isEmpty && date != result) { return (nil, true) }
            } else { result = date }
            body.removeSubrange(hit.range)
        }
        let hasExtraDate = match(explicitDayPattern, in: body) != nil || match(relativeDayPattern, in: body) != nil || match(weekdayPattern, in: body) != nil
        return (result, hasExtraDate)
    }

    private func extractTime(from body: inout String, day: Date?, allowNextClock: Bool, due: inout Due) -> Bool {
        let clock = "(?:(" + periods + ")[，,\\s]*)?\\s*(?:差(" + numbers + ")分(?:钟)?\\s*)?(" + numbers + ")(?:点(?:钟)?|时|[:：])(?:(半|一刻|三刻|" + numbers + ")(?:分)?(?![点时:：]))?(?:过(" + numbers + ")分(?:钟)?)?"
        let delay = "(半|" + numbers + ")(?:个)?(小时|分钟)(?:之|以)?后"
        if let hit = match(delay, in: body) {
            let minutes: Int?
            if hit.groups[0] == "半" { minutes = hit.groups[1] == "小时" ? 30 : nil }
            else { minutes = number(hit.groups[0]).map { $0 * (hit.groups[1] == "小时" ? 60 : 1) } }
            guard day == nil, let amount = minutes, amount > 0, let date = calendar.date(byAdding: .minute, value: amount, to: now) else { return false }
            body.removeSubrange(hit.range)
            guard match(clock, in: body) == nil, match(delay, in: body) == nil,
                  match(numbers + "(?:个)?(?:小时|分钟)", in: body) == nil else { return false }
            due.kind = .timed
            due.date = date
            return true
        }
        guard let hit = match(clock, in: body) else {
            if let day { due.kind = .allDay; due.date = day }
            return true
        }
        guard var hour = number(hit.groups[2]), (0..<24).contains(hour) else { return false }
        let period = hit.groups[0]
        if ["凌晨","上午","早晨","清晨","清早","早间","早上"].contains(period) && hour > 12 { return false }
        guard day != nil || (allowNextClock && (!period.isEmpty || hour > 12 || hour == 0)) else { return false }
        if ["下午","晚上","晚间","傍晚","中午"].contains(period) && hour < 12 && (period != "中午" || hour <= 4) { hour += 12 }
        if ["凌晨","上午","早晨","清晨","清早","早间","早上"].contains(period) && hour == 12 { hour = 0 }
        let minute = ["半": 30, "一刻": 15, "三刻": 45][hit.groups[3]] ?? number(hit.groups[3]) ?? 0
        let before = number(hit.groups[1]) ?? 0
        let after = number(hit.groups[4]) ?? 0
        guard (0..<60).contains(minute), (0..<60).contains(before), (0..<60).contains(after),
              before == 0 || after == 0, after == 0 || minute == 0,
              let base = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day ?? now),
              var date = calendar.date(byAdding: .minute, value: after - before, to: base) else { return false }
        if day == nil && date <= now {
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return false }
            date = next
        }
        body.removeSubrange(hit.range)
        guard match(clock, in: body) == nil else { return false }
        due.kind = .timed
        due.date = date
        return true
    }

    private func match(_ pattern: String, in text: String) -> (range: Range<String.Index>, full: String, groups: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let hit = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(hit.range, in: text) else { return nil }
        let groups = (1..<hit.numberOfRanges).map { i in
            Range(hit.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
        return (range, String(text[range]), groups)
    }

    private func number(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 4 else { return nil }
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        if !text.contains("十") && !text.contains("百") {
            return text.allSatisfy { digits[$0] != nil } ? text.reduce(0) { $0 * 10 + digits[$1]! } : nil
        }
        var total = 0, digit = 0
        for c in text {
            if c == "十" || c == "百" { total += max(1, digit) * (c == "十" ? 10 : 100); digit = 0 }
            else if let n = digits[c] { digit = n } else { return nil }
        }
        return total + digit
    }
}

