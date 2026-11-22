import SwiftUI
import os

private enum EditorRoute: Identifiable {
    case new, settings, edit(Item), rename(Item), reminder(Item), review([ParsedTask], String)
    var id: String {
        switch self {
        case .new: "new"
        case .settings: "settings"
        case .edit(let item): item.id.uuidString
        case .rename(let item): "rename-" + item.id.uuidString
        case .reminder(let item): "reminder-" + item.id.uuidString
        case .review: "review"
        }
    }
}

struct TaskList: View {
    @Bindable var store: TaskStore
    private var active: [Item] { store.openItems }
    @State private var history: [Item] = []
    @State private var expanded = false
    @State private var activeLimit = 40
    @State private var historyLimit = 40
    @State private var route: EditorRoute?
    @State private var capture: Capture
    @State private var pressStart: Date?
    @State private var startedFromIdle = false
    @State private var cancelGesture = false
    @State private var feedback = ""
    @State private var addedItems: [Item] = []
    @State private var undoAction: (() throws -> Void)?
    @State private var hideFeedback: Task<Void, Never>?
    @State private var ready = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    init(store: TaskStore, capture: Capture? = nil) {
        self.store = store
        _capture = State(initialValue: capture ?? Capture())
    }

    var body: some View {
        NavigationStack {
            List {
                if active.isEmpty {
                    Section {
                        VStack(spacing: 14) {
                            Image(systemName: "checklist").font(.system(size: 32, weight: .light))
                                .frame(width: 76, height: 76).background(.quaternary.opacity(0.55), in: Circle())
                                .accessibilityHidden(true)
                            Text("没有待办").font(.title3.weight(.semibold))
                            Text("按住下方麦克风说一件事，\n或点右上角的加号写下来。")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 52)
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(active) { item in row(item) }
                        if active.count == activeLimit {
                            ProgressView().frame(maxWidth: .infinity).onAppear { activeLimit += 40; reload() }
                        }
                    } header: { if !active.isEmpty { Text("未完成") } }
                }
                Section {
                    Button {
                        expanded.toggle()
                        historyLimit = 40
                        reload()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                            Text("已完成")
                            Spacer()
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                        }.foregroundStyle(.primary).frame(minHeight: 36)
                    }
                    .accessibilityValue(expanded ? "已展开" : "已折叠").accessibilityIdentifier("history")
                    if expanded {
                        if history.isEmpty { Text("还没有已完成的待办").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(history) { item in row(item) }
                        if history.count == historyLimit {
                            ProgressView().onAppear { historyLimit += 40; reload() }
                        }
                    }
                }
            }.listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
            .navigationTitle("待办")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        capture.cancel()
                        route = .settings
                    } label: { Label("设置", systemImage: "gearshape") }
                    .accessibilityIdentifier("settings")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { capture.cancel(); route = .new } label: { Image(systemName: "plus") }
                        .accessibilityLabel("手动添加").accessibilityIdentifier("add")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .sheet(item: $route, onDismiss: {
                if !addedItems.isEmpty { scheduleFeedbackDismissal() }
            }) { route in
                switch route {
                case .settings: GlobalSettings(store: store)
                case .new: TaskEditor(store: store, onInsert: { added([$0]) })
                case .edit(let item): TaskEditor(store: store, item: item)
                case .rename(let item): QuickTitleEditor(item: item, store: store)
                case .reminder(let item):
                    ReminderSettings(store: store, draft: item.draft, item: item, scheduled: item.desiredReminder,
                                     chooseTime: item.reminderIssue() == .needsTime) { edit in
                        let current = item.draft
                        let updated = try edit.applied(to: current)
                        if updated != current { try store.update(item, with: updated) }
                    }
                case .review(let rows, let original): ReviewView(rows: rows, original: original) { drafts in
                    let items = try store.insert(drafts)
                    self.route = nil
                    added(items)
                }
                }
            }
        }
        .onAppear {
            capture.onResult = process
            if !ready {
                ready = true
                OSSignposter(subsystem: "local.saywhen.app", category: "Launch").emitEvent("ListInteractive")
            }
            handleRoute()
        }
        .task(id: phase) {
            guard phase == .active else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { store.refresh(); capture.warm(store.preferences) }
        }
        .onChange(of: store.preferences) { capture.warm(store.preferences) }
        .onChange(of: store.change) { reload() }
        .onChange(of: AppRoute.shared.itemID) { handleRoute() }
        .onChange(of: AppRoute.shared.capture) { handleRoute() }
        .onChange(of: phase) { _, new in
            if new == .active {
                if route == nil && ready { DisplayMark.nextFrame(.foreground) }
                handleRoute()
            }
            if new == .background && capture.phase != .idle { capture.fallback("录入已暂停，可以继续编辑。") }
        }
        .alert("暂时无法完成操作", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: 5) {
            Button {
                do {
                    let began = CACurrentMediaTime()
                    try store.toggle(item) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    DisplayMark.nextFrame(.completion, began: began)
                    toast(item.isDone ? "已完成" : "已恢复") { try store.toggle(item) }
                } catch { store.errorMessage = error.localizedDescription }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(item.isDone ? .secondary : .primary)
                    .frame(width: 44, height: 46)
            }.accessibilityLabel((item.isDone ? "恢复" : "标为完成") + "，" + item.title)
                .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    capture.cancel()
                    clearFeedback()
                    route = .edit(item)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.body).strikethrough(item.isDone)
                                .foregroundStyle(item.isDone ? .secondary : .primary)
                            if item.kind != DateKind.none.rawValue {
                                Text(Due(kind: DateKind(rawValue: item.kind) ?? .none, date: item.time, zone: item.zone).label)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if item.hasNotes { Image(systemName: "note.text").font(.footnote).foregroundStyle(.secondary) }
                    }.contentShape(Rectangle()).frame(minHeight: 46)
                }.buttonStyle(.plain).accessibilityLabel("打开备注，" + item.title)
                    .accessibilityValue(item.kind == DateKind.none.rawValue ? "" :
                        Due(kind: DateKind(rawValue: item.kind) ?? .none, date: item.time, zone: item.zone).label)
                if let issue = item.reminderIssue() {
                    Button {
                        capture.cancel()
                        clearFeedback()
                        route = .reminder(item)
                    } label: {
                        Label(issue.label, systemImage: issue == .denied ? "bell.slash" : "bell.badge")
                            .font(.caption).frame(minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(issue.label + "，" + item.title)
                    .accessibilityHint("打开提醒设置")
                    .accessibilityIdentifier("row.reminderIssue")
                }
            }
        }.listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 16))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if !addedItems.isEmpty {
                AddedReceipt(items: addedItems, edit: { item in
                    hideFeedback?.cancel()
                    route = .rename(item)
                }, undo: undo)
            } else if !feedback.isEmpty {
                HStack {
                    Text(feedback).font(.footnote)
                    Spacer()
                    Button("撤销", action: undo)
                }.font(.subheadline).padding(.horizontal, 8)
            }
            if capture.phase != .idle {
                HStack {
                    Text(cancelGesture ? "松开取消" : capture.message).font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if capture.phase != .typing {
                        Button("键入") { capture.fallback("键入待办，也可以使用键盘听写。") }.font(.subheadline)
                    }
                    Button("取消") { capture.cancel() }.font(.subheadline)
                }
                if capture.phase == .typing {
                    TextField("键入刚才想说的事", text: $capture.transcript, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...5).accessibilityIdentifier("capture.text")
                } else if !capture.transcript.isEmpty { Text(capture.transcript).frame(maxWidth: .infinity, alignment: .leading) }
                if capture.phase == .typing {
                    HStack {
                        Button("再说一次") { capture.start(preferences: store.preferences) }
                        if capture.message.contains("授权") || capture.message.contains("麦克风或") {
                            Button("前往设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                        }
                        Spacer()
                        Button("完成") { capture.submit() }.disabled(capture.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if capture.phase != .typing || pressStart != nil {
                let isRecording = capture.phase == .listening
                HStack(spacing: 10) {
                    Image(systemName: isRecording ? "waveform" : "mic.fill")
                        .foregroundStyle(isRecording ? Color.red : Color(uiColor: .systemBackground))
                    Text(capture.phase == .idle ? "按住说话" : isRecording ? "正在听 · 完成" : capture.message)
                        .font(.headline)
                }
                .foregroundStyle(Color(uiColor: .systemBackground)).frame(maxWidth: .infinity)
                .padding(.vertical, 16).background(Color.primary, in: Capsule()).contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if pressStart == nil {
                        pressStart = .now
                        startedFromIdle = capture.phase == .idle
                        if startedFromIdle { clearFeedback(); capture.start(preferences: store.preferences) }
                    }
                    cancelGesture = value.translation.height < -55
                }.onEnded { value in
                    let held = Date().timeIntervalSince(pressStart ?? .now) >= 0.35
                    if cancelGesture || value.translation.height < -55 { capture.cancel() }
                    else if (held || !startedFromIdle) && capture.phase != .typing { capture.finish() }
                    pressStart = nil
                    cancelGesture = false
                })
                .accessibilityElement(children: .ignore).accessibilityLabel(capture.phase == .idle ? "按住说话" : "完成录入")
                .accessibilityHint("轻点开始，再点完成。长按时向上滑动可取消。")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { if capture.phase == .idle { capture.start(preferences: store.preferences) } else { capture.finish() } }
            }
        }
        .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private func reload() {
        do {
            store.openItems = try store.page(done: false, limit: activeLimit)
            history = expanded ? try store.page(done: true, limit: historyLimit) : []
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func process(_ text: String, _ began: Date, _ zone: TimeZone) {
        let parsed = MandarinParser(now: began, zone: zone).parse(text)
        if let draft = MandarinParser.directDraft(from: parsed) {
            do { added(try store.insert([draft])) }
            catch { route = .review(parsed, text); store.errorMessage = error.localizedDescription }
        } else { route = .review(parsed, text) }
    }

    private func handleRoute() {
        if let id = AppRoute.shared.itemID {
            AppRoute.shared.itemID = nil
            do {
                if let item = try store.item(id: id) { capture.cancel(); route = .edit(item) }
                else { store.errorMessage = "这条待办已删除。" }
            } catch { store.errorMessage = error.localizedDescription }
        }
        if AppRoute.shared.capture {
            AppRoute.shared.capture = false
            route = nil
            capture.start(preferences: store.preferences)
        }
    }

    private func added(_ items: [Item]) {
        clearFeedback()
        addedItems = items
        undoAction = { try store.remove(items) }
        scheduleFeedbackDismissal()
    }

    private func undo() {
        do { try undoAction?(); clearFeedback() } catch { store.errorMessage = error.localizedDescription }
    }

    private func toast(_ text: String, undo: @escaping () throws -> Void) {
        clearFeedback()
        feedback = text
        undoAction = undo
        scheduleFeedbackDismissal()
    }

    private func scheduleFeedbackDismissal() {
        hideFeedback?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        let seconds = addedItems.isEmpty ? 7 : 10
        hideFeedback = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { clearFeedback() }
        }
    }

    private func clearFeedback() {
        hideFeedback?.cancel()
        undoAction = nil
        feedback = ""
        addedItems = []
    }
}

private struct ReviewView: View {
    @State var rows: [ParsedTask]
    let original: String
    let save: ([Draft]) throws -> Void
    @State private var error: String?
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("刚才说的") { Text(original).foregroundStyle(.secondary).textSelection(.enabled) }
                ForEach($rows) { $row in
                    Section {
                        TextField("待办标题", text: $row.draft.title, axis: .vertical)
                        if let question = row.question { Text(question).font(.subheadline).foregroundStyle(.secondary) }
                        if !row.candidates.isEmpty {
                            ForEach(row.candidates, id: \.self) { date in
                                Button(Due.format(date, zone: row.draft.due.calendar.timeZone, pattern: "M月d日 EEEE")) {
                                    row.draft.due.kind = .allDay
                                    row.draft.due.date = date
                                }
                            }
                        }
                        if let missing = row.missingTime {
                            KnownDayActions(row: $row, missing: missing)
                        } else {
                            DateFields(due: $row.draft.due)
                                .onChange(of: row.draft.due.kind) { _, kind in
                                    if kind == .allDay && row.draft.rule == .atDue { row.draft.rule = .off }
                                }
                            if row.draft.rule == .off { Text("仅保存，不安排提醒").font(.footnote).foregroundStyle(.secondary) }
                            if row.draft.rule == .custom {
                                Text("提醒 " + Due(kind: .timed, date: row.draft.customTime, zone: row.draft.due.zone).shortLabel)
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        TextField("添加备注", text: $row.draft.notes, axis: .vertical)
                    }
                }
                if let error { Text(error) }
            }
            .navigationTitle("核对待办").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try save(rows.map(\.draft)) } catch { self.error = error.localizedDescription }
                    }.disabled(!rows.allSatisfy { $0.draft.valid && $0.missingTime == nil })
                }
            }
        }
    }
}

