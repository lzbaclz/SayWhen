import SwiftUI

enum TimingChoice: Hashable {
    case rule(ReminderRule), minutes(Int), otherInterval

    init(rule: ReminderRule, minutes: Int) {
        if rule == .lead { self = DefaultAdvance.presets.contains(minutes) ? .minutes(minutes) : .otherInterval }
        else { self = .rule(rule) }
    }

    var rule: ReminderRule {
        switch self {
        case .rule(let rule): rule
        case .minutes, .otherInterval: .lead
        }
    }

    func interval(using input: IntervalInput) -> Int? {
        switch self {
        case .minutes(let value): value
        case .otherInterval: input.minutes
        case .rule: nil
        }
    }
}

struct IntervalInput {
    var amount: String
    var inHours: Bool

    init(minutes: Int) {
        inHours = minutes > 0 && minutes.isMultiple(of: 60)
        amount = String(inHours ? minutes / 60 : minutes)
    }

    var minutes: Int? {
        let unit = inHours ? 60 : 1
        guard let value = Int(amount), value > 0, value <= Int(Int32.max) / unit else { return nil }
        return value * unit
    }
}

struct AdvanceChoices: View {
    var body: some View {
        Text(DefaultAdvance.previousEvening.label).tag(TimingChoice.rule(.previousEvening))
        ForEach(DefaultAdvance.presets, id: \.self) { value in
            Text(DefaultAdvance.label(minutes: value)).tag(TimingChoice.minutes(value))
        }
        Text("自定义提前量").tag(TimingChoice.otherInterval)
    }
}

struct IntervalField: View {
    @Binding var input: IntervalInput
    var body: some View {
        TextField("提前数量", text: $input.amount)
            .keyboardType(.numberPad).accessibilityIdentifier("advance.amount")
        Picker("单位", selection: $input.inHours) {
            Text("小时").tag(true)
            Text("分钟").tag(false)
        }.pickerStyle(.segmented)
        if input.minutes == nil { Text("请输入有效的正整数。").font(.footnote) }
    }
}

struct GlobalSettings: View {
    let store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var choice: TimingChoice
    @State private var interval: IntervalInput
    @State private var language: SpeechLanguage
    @State private var vocabulary: String
    @State private var privacy = false
    @State private var error: String?

    init(store: TaskStore) {
        self.store = store
        let settings = store.preferences
        switch settings.advance {
        case .previousEvening:
            _choice = State(initialValue: .rule(.previousEvening))
            _interval = State(initialValue: IntervalInput(minutes: 120))
        case .minutes(let count):
            _choice = State(initialValue: TimingChoice(rule: .lead, minutes: count))
            _interval = State(initialValue: IntervalInput(minutes: count))
        }
        _language = State(initialValue: settings.language)
        _vocabulary = State(initialValue: settings.vocabulary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("默认提醒", selection: $choice) { AdvanceChoices() }
                        .pickerStyle(.menu).accessibilityIdentifier("settings.default")
                    if choice == .otherInterval { IntervalField(input: $interval) }
                } footer: {
                    Text("用于跟随全局的待办。全天事项从当天 00:00 计算提前量。明确说出的提醒钟点及单条设置优先。")
                }
                Section("语音识别") {
                    Picker("主要语言", selection: $language) {
                        ForEach(SpeechLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("常用专名，每行一个", text: $vocabulary, axis: .vertical)
                        .lineLimit(2...6).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("settings.vocabulary")
                    Text("可添加人名、项目名和英文缩写。CVPR、GitHub、PDF 等常用词已内置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("隐私政策") { privacy = true }.accessibilityIdentifier("privacy")
                }
                if let error { Section { Text(error) } }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let advance = choice.interval(using: interval).map(DefaultAdvance.minutes) ?? .previousEvening
                        do {
                            try store.savePreferences(AppPreferences(advance: advance, language: language, vocabulary: vocabulary))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(choice == .otherInterval && interval.minutes == nil)
                    .accessibilityIdentifier("settings.save")
                }
            }
            .sheet(isPresented: $privacy) { PrivacyPolicyView() }
        }
    }
}
