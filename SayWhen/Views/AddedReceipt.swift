import SwiftUI

struct AddedReceipt: View {
    let items: [Item]
    let edit: (Item) -> Void
    let undo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(items.count == 1 ? "已记下" : "已记下 \(items.count) 条")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("撤销", action: undo).font(.subheadline)
            }
            if items.count == 1, let item = items.first {
                entry(item)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        ForEach(items) { item in entry(item).frame(maxWidth: 270, alignment: .leading) }
                    }
                }
            }
        }
    }

    private func entry(_ item: Item) -> some View {
        let due = Due(kind: DateKind(rawValue: item.kind) ?? .none, date: item.time, zone: item.zone)
        return Button { edit(item) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title).font(.headline).lineLimit(3)
                    Image(systemName: "pencil").font(.footnote)
                }.foregroundStyle(.tint)
                if let date = item.desiredReminder {
                    let time = Due(kind: .timed, date: date, zone: item.zone).shortLabel
                    if due.kind != .timed || date != due.date {
                        Text("到期 " + due.shortLabel).font(.subheadline)
                    }
                    Text(item.reminderStatus == "已安排" ? time + " 提醒" : "计划提醒 " + time + " · " + item.reminderStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(due.shortLabel).font(.subheadline)
                    if item.reminderIssue() == .needsTime {
                        Text("提醒时刻已过，可在待办旁选时间").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("轻点修改标题")
        .accessibilityIdentifier("receipt.editTitle")
    }
}

struct QuickTitleEditor: View {
    let item: Item
    let store: TaskStore
    @State private var text: String
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(item: Item, store: TaskStore) {
        self.item = item
        self.store = store
        _text = State(initialValue: item.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("待办标题", text: $text, axis: .vertical)
                    .focused($focused)
                    .accessibilityIdentifier("rename.title")
                if let error { Text(error) }
            }
            .navigationTitle("修改标题").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var draft = item.draft
                        draft.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            if draft.title != item.title { try store.update(item, with: draft) }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("rename.save")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
