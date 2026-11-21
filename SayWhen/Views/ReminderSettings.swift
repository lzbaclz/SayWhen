import SwiftUI

struct ReminderSettings: View {
    let store: TaskStore
    let draft: Draft
    let item: Item?
    let save: (ReminderEdit) throws -> Void

    @State private var edit: ReminderEdit
    @State private var choice: TimingChoice
    @State private var interval: IntervalInput
    @State private var error: String?
    @State private var confirmLate = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(store: TaskStore, draft: Draft, item: Item?, scheduled: Date?, chooseTime: Bool = false,
         save: @escaping (ReminderEdit) throws -> Void) {
        self.store = store
        self.draft = draft
        self.item = item
        self.save = save
        let value = ReminderEdit(draft: draft, scheduled: scheduled, chooseTime: chooseTime, defaultAdvance: store.preferences.advance)
        _edit = State(initialValue: value)
        _choice = State(initialValue: TimingChoice(rule: value.rule, minutes: value.leadMinutes))
        _interval = State(initialValue: IntervalInput(minutes: value.leadMinutes))
    }

    private var proposal: ReminderEdit? {
        var next = edit
        next.rule = choice.rule
        if choice.rule == .lead {
            guard let minutes = choice.interval(using: interval) else { return nil }
            next.leadMinutes = minutes
        }
        return next
    }

    var body: some View {
        NavigationStack {
            Form {
                if let problem = item?.reminderIssue() {
                    Section {
                        switch problem {
                        case .denied:
                            Text("通知未开启，这条待办不会提醒。")
                            Button("前往通知设置") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }
                        case .full:
                            Text("系统待发名额已满。有空位并再次打开 App 时，会优先安排最近的提醒。")
                            Button("检查名额") { store.refresh(ask: true) }
                        case .pending:
                            Text("这条提醒尚未排入系统。")
                            Button("重新安排") { store.refresh(ask: true) }
                        case .needsTime:
                            Text("原提醒时刻已过，可重新选时间或仅保存待办。")
                        }
                    }
                }
                Section("到期") { Text(draft.due.label) }
                Section {
                    Picker("提醒方式", selection: $choice) {
                        Text("跟随全局 · " + store.preferences.advance.label).tag(TimingChoice.rule(.followDefault))
                        if draft.due.kind == .timed { Text("到点提醒").tag(TimingChoice.rule(.atDue)) }
                        AdvanceChoices()
                        Text("提前一天").tag(TimingChoice.rule(.previousDay))
                        Text("自选时间").tag(TimingChoice.rule(.custom))
                        Text("仅保存").tag(TimingChoice.rule(.off))
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("reminder.mode")
                    if choice == .otherInterval { IntervalField(input: $interval) }
                    if choice.rule == .lead && draft.due.kind == .allDay {
                        Text("全天事项从当天 00:00 计算提前量。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if choice.rule == .custom {
                        TaskDatePicker(title: "提醒时间", date: $edit.time, includesTime: true, zone: draft.due.calendar.timeZone)
                        if edit.time <= .now {
                            Text("请选择将来的提醒时刻。").font(.footnote)
                        }
                    }
                    if let proposal, let updated = try? proposal.applied(to: draft),
                       let next = updated.nextReminder(after: .now, defaultAdvance: store.preferences.advance) {
                        LabeledContent(item?.reminderIssue() == .denied ? "计划提醒" : "将提醒于",
                                       value: Due.format(next, zone: draft.due.calendar.timeZone, pattern: "yyyy年M月d日 EEEE HH:mm z"))
                    } else if proposal != nil && choice.rule != .off && choice.rule != .custom {
                        Text("默认时刻已过，可自选时间或仅保存。").font(.footnote)
                    }
                }
                if let error { Text(error) }
            }
            .navigationTitle("设置提醒").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("reminder.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        if proposal?.isLate(for: draft.due) == true { confirmLate = true }
                        else { confirm() }
                    }
                    .disabled(proposal == nil || (choice.rule == .custom && edit.time <= .now))
                    .accessibilityIdentifier("reminder.confirm")
                }
            }
            .alert("提醒晚于到期时间", isPresented: $confirmLate) {
                Button("仍在这个时间提醒") { confirm() }
                Button("继续修改", role: .cancel) {}
            } message: {
                Text("选定的提醒为 " + Due.format(edit.time, zone: draft.due.calendar.timeZone, pattern: "yyyy年M月d日 HH:mm z") + "。")
            }
        }
    }

    private func confirm() {
        guard let proposal else { return }
        do { try save(proposal); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
