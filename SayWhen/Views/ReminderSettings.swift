import SwiftUI

struct ReminderSettings: View {
    let store: TaskStore
    let draft: Draft
    let item: Item?
    let save: (ReminderEdit) throws -> Void

    @State private var edit: ReminderEdit
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
        _edit = State(initialValue: ReminderEdit(draft: draft, scheduled: scheduled, chooseTime: chooseTime))
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
                    Picker("提醒方式", selection: $edit.rule) {
                        if draft.due.kind == .timed { Text("到点提醒").tag(ReminderRule.atDue) }
                        Text("提前一天").tag(ReminderRule.previousDay)
                        if draft.rule == .lead { Text("提前 \(draft.leadMinutes) 分钟").tag(ReminderRule.lead) }
                        Text("自选时间").tag(ReminderRule.custom)
                        Text("仅保存").tag(ReminderRule.off)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("reminder.mode")
                    if edit.rule == .custom {
                        TaskDatePicker(title: "提醒时间", date: $edit.time, includesTime: true, zone: draft.due.calendar.timeZone)
                        if edit.time <= .now {
                            Text("请选择将来的提醒时刻。").font(.footnote)
                        }
                    }
                    if let updated = try? edit.applied(to: draft), let next = updated.nextReminder(after: .now) {
                        LabeledContent(item?.reminderIssue() == .denied ? "计划提醒" : "将提醒于",
                                       value: Due.format(next, zone: draft.due.calendar.timeZone, pattern: "yyyy年M月d日 EEEE HH:mm z"))
                    } else if edit.rule != .off && edit.rule != .custom {
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
                        if edit.isLate(for: draft.due) { confirmLate = true }
                        else { confirm() }
                    }
                    .disabled(edit.rule == .custom && edit.time <= .now)
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
        do { try save(edit); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
