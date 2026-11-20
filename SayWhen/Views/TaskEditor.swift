import SwiftUI
import EventKit

struct TaskDatePicker: View {
    let title: String
    @Binding var date: Date
    let includesTime: Bool
    let zone: TimeZone
    @Environment(\.dynamicTypeSize) private var size
    @State private var choosing = false

    private var display: String {
        Due.format(date, zone: zone, pattern: includesTime ? "yyyy年M月d日 HH:mm" : "yyyy年M月d日")
    }

    var body: some View {
        if size.isAccessibilitySize {
            Button { choosing = true } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).foregroundStyle(.primary)
                    Text(display).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("accessible.date." + title)
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: 12) {
                            Text(display).frame(maxWidth: .infinity, alignment: .leading)
                            DatePicker("日期", selection: $date, displayedComponents: .date)
                                .labelsHidden().datePickerStyle(.wheel)
                            if includesTime {
                                DatePicker("时间", selection: $date, displayedComponents: .hourAndMinute)
                                    .labelsHidden().datePickerStyle(.wheel)
                            }
                        }.padding().environment(\.timeZone, zone)
                    }
                    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { choosing = false } } }
                }
            }
        } else {
            DatePicker(title, selection: $date, displayedComponents: includesTime ? [.date,.hourAndMinute] : [.date])
                .environment(\.timeZone, zone)
        }
    }
}

struct DateFields: View {
    @Binding var due: Due
    @Environment(\.dynamicTypeSize) private var size
    private var kindPicker: some View {
        Picker("到期方式", selection: $due.kind) {
            Text("无日期").tag(DateKind.none)
            Text("全天").tag(DateKind.allDay)
            Text("定时").tag(DateKind.timed)
        }
    }

    var body: some View {
        if size.isAccessibilitySize { kindPicker.pickerStyle(.menu) }
        else { kindPicker.pickerStyle(.segmented) }
        if due.kind != .none {
            TaskDatePicker(title: "到期", date: $due.date, includesTime: due.kind == .timed, zone: due.calendar.timeZone)
            if due.kind == .timed && due.zone != TimeZone.current.identifier { Text(due.zone).font(.footnote) }
        }
    }
}

struct TaskEditor: View {
    let store: TaskStore
    let onInsert: ((Item) -> Void)?
    @State var item: Item?
    @State private var draft: Draft
    @State private var savedDraft: Draft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    @State private var saving: Task<Void, Never>?
    @State private var error: String?
    @State private var deleting = false
    @State private var pickDate = false
    @State private var syncAfterDate = false
    @State private var calendarPanel = false
    @State private var reminderPanel = false
    @State private var discard = false

    init(store: TaskStore, item: Item? = nil, onInsert: ((Item) -> Void)? = nil) {
        self.onInsert = onInsert
        self.store = store
        _item = State(initialValue: item)
        var value = item?.draft ?? Draft()
        if item == nil {
            let calendar = value.due.calendar
            value.due.date = calendar.dateInterval(of: .hour, for: Date())?.end ?? Date().addingTimeInterval(3600)
        }
        _draft = State(initialValue: value)
        _savedDraft = State(initialValue: value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("事项") {
                    TextField("待办标题", text: $draft.title, axis: .vertical).accessibilityIdentifier("editor.title")
                }
                Section("日期与时间") { DateFields(due: $draft.due) }
                if draft.due.kind != .none {
                    Section("提醒") {
                        Button { reminderPanel = true } label: {
                            LabeledContent("提醒方式", value: draft.reminderLabel)
                        }
                        .accessibilityHint("点开修改，确定后生效")
                        .accessibilityIdentifier("editor.reminder")
                        if item?.isDone == true { Text("已完成，待发提醒已取消").font(.footnote) }
                        else if let next = displayedReminder {
                            Text(Due.format(next, zone: draft.due.calendar.timeZone, pattern: "yyyy年M月d日 EEEE HH:mm z"))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if next <= .now { Text("提醒时刻已过").font(.footnote).foregroundStyle(.secondary) }
                            else if let item, !item.reminderStatus.isEmpty {
                                LabeledContent("通知状态", value: item.reminderStatus)
                                if item.reminderStatus == "通知未开启" {
                                    Button("前往通知设置") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }
                                } else if item.reminderStatus == "提醒待安排" || item.reminderStatus == "提醒名额已满" {
                                    Button("重新安排") { store.refresh(ask: true) }
                                }
                            }
                        } else if draft.rule != .off {
                            Text("提醒时刻已过，可选其他时间或仅保存。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("备注") {
                    TextField("添加备注", text: $draft.notes, axis: .vertical).lineLimit(3...16)
                        .accessibilityIdentifier("editor.notes")
                }
                if let error {
                    Section { Text(error); Button("重试保存") { _ = flush() } }
                }
                if let item {
                    Section {
                        Button {
                            guard flush() else { return }
                            if draft.due.kind == .none { pickDate = true }
                            else { calendarPanel = true }
                        } label: {
                            Label(calendarAction(item), systemImage: "calendar.badge.plus")
                        }.accessibilityIdentifier("editor.calendar")
                        if let link = item.receipt, let date = link.syncedAt {
                            Text("\(link.calendarName) · 上次同步 " + Due.format(date, zone: .current, pattern: "M月d日 HH:mm"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section { Button("删除待办", role: .destructive) { deleting = true } }
                }
            }
            .navigationTitle(item == nil ? "新建待办" : "待办详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(item == nil ? "取消" : "返回") {
                        if item == nil { dismiss() }
                        else if flush() { dismiss() }
                        else { discard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "添加" : "完成") { if flush() { dismiss() } }
                        .disabled(!draft.valid).accessibilityIdentifier("editor.save")
                }
            }
            .alert("删除这条待办？", isPresented: $deleting) {
                Button("删除", role: .destructive) {
                    guard let item else { return }
                    saving?.cancel()
                    do { try store.remove([item]); dismiss() } catch { self.error = error.localizedDescription }
                }
                Button("取消", role: .cancel) {}
            } message: { Text(item?.calendarLink == nil ? "待发提醒也会取消。" : "待发提醒将取消。苹果日历中的日程会保留。") }
            .confirmationDialog("修改尚未保存", isPresented: $discard) {
                Button("放弃本次修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
            .sheet(isPresented: $pickDate, onDismiss: {
                if syncAfterDate { syncAfterDate = false; calendarPanel = true }
            }) {
                ChooseDate { date in
                    draft.due.date = date
                    draft.due.kind = .allDay
                    syncAfterDate = flush()
                    pickDate = false
                }
            }
            .sheet(isPresented: $calendarPanel) {
                if let item { CalendarPanel(item: item, store: store) }
            }
            .sheet(isPresented: $reminderPanel) {
                ReminderSettings(store: store, draft: draft, item: item, scheduled: displayedReminder) { edit in
                    let updated = try edit.applied(to: draft)
                    if let item, savedDraft != updated {
                        try store.update(item, with: updated)
                        savedDraft = updated
                    }
                    draft = updated
                    error = nil
                }
            }
        }
        .onChange(of: draft.due.kind) { _, kind in
            if kind == .allDay && draft.rule == .atDue { draft.rule = .off }
        }
        .interactiveDismissDisabled(draft != savedDraft)
        .onChange(of: draft) {
            saving?.cancel()
            guard item != nil else { return }
            saving = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                _ = flush()
            }
        }
        .onChange(of: phase) { _, new in
            if new != .active && item != nil && draft != savedDraft { _ = flush() }
        }
        .onDisappear { saving?.cancel() }
    }

    private var displayedReminder: Date? {
        if let item, savedDraft == draft { return item.desiredReminder }
        return draft.nextReminder(after: .now)
    }

    private func calendarAction(_ item: Item) -> String {
        guard let receipt = item.receipt, receipt.syncedAt != nil else { return "同步到日历" }
        return receipt.local == EventFields(item) ? "核对日历" : "更新到日历"
    }

    private func flush() -> Bool {
        do {
            if let item {
                if savedDraft != draft { try store.update(item, with: draft) }
            } else {
                item = try store.insert([draft]).first
                if let item { onInsert?(item) }
            }
            savedDraft = draft
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

private struct ChooseDate: View {
    @State private var day = Date()
    @Environment(\.dismiss) var dismiss
    let chosen: (Date) -> Void
    var body: some View {
        NavigationStack {
            DatePicker("日期", selection: $day, displayedComponents: [.date]).datePickerStyle(.graphical).padding()
                .navigationTitle("补选日期")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("继续") { chosen(day) } }
                }
        }.presentationDetents([.medium, .large])
    }
}

private struct CalendarPanel: View {
    let item: Item
    let store: TaskStore
    @State private var service = CalendarSync()
    @State private var calendars: [EKCalendar] = []
    @State private var selected = ""
    @State private var message: String?
    @State private var conflict: EventFields?
    @State private var missing = false
    @State private var checkedMissing = false
    @State private var working = true
    @Environment(\.dismiss) var dismiss
    @Environment(\.openURL) var openURL

    var body: some View {
        NavigationStack {
            Form {
                if working { ProgressView("正在读取日历") }
                if !calendars.isEmpty {
                    Section {
                        Picker("目标日历", selection: $selected) {
                            ForEach(calendars, id: \.calendarIdentifier) { cal in
                                Text("\(cal.title) · \(cal.source.title)").tag(cal.calendarIdentifier)
                            }
                        }.disabled(item.receipt != nil && !missing)
                        LabeledContent("待办", value: item.title)
                        Text(item.draft.due.label)
                        if !item.notes.isEmpty { Text(item.notes) }
                    } footer: { Text("将写入标题、时间和备注。共享日历的成员可能看见这些内容。") }
                }
                if let message { Section { Text(message) } }
                if conflict != nil {
                    Button("用待办内容覆盖冲突字段") { write(overwrite: true) }
                } else if missing {
                    Toggle("我已核对苹果日历", isOn: $checkedMissing)
                    Button("重新添加日程") { write(recreate: true) }.disabled(!checkedMissing || selected.isEmpty)
                } else if !calendars.isEmpty {
                    Button("确认同步") { write() }.disabled(working || selected.isEmpty)
                } else if !working {
                    Button("前往系统设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    Button("重试") { Task { await load() } }
                }
            }
            .navigationTitle("同步到日历").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await load() }
        }.presentationDetents([.medium,.large])
    }

    private func load() async {
        working = true
        defer { working = false }
        do {
            calendars = try await service.calendars()
            let old = item.receipt?.calendarID
            selected = [old, service.events.defaultCalendarForNewEvents?.calendarIdentifier, calendars.first?.calendarIdentifier]
                .compactMap { $0 }.first(where: { id in calendars.contains { $0.calendarIdentifier == id } }) ?? ""
            missing = old != nil && old != selected
            message = missing ? SyncFailure.lost.localizedDescription : nil
        } catch { message = error.localizedDescription }
    }

    private func write(overwrite: Bool = false, recreate: Bool = false) {
        guard !working, let target = calendars.first(where: { $0.calendarIdentifier == selected }) else { return }
        working = true
        defer { working = false }
        do {
            try service.write(item, to: target, in: store, replaceMissing: recreate, confirmedRemote: overwrite ? conflict : nil)
            dismiss()
        } catch SyncFailure.conflict(let lines, let remote) {
            conflict = remote
            message = lines.joined(separator: "\n\n")
        } catch SyncFailure.lost {
            conflict = nil
            missing = true
            message = SyncFailure.lost.localizedDescription
        } catch { message = "待办已保存，日历未更新。\n" + error.localizedDescription }
    }
}

