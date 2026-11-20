import SwiftUI

struct KnownDayActions: View {
    @Binding var row: ParsedTask
    let missing: MissingTime
    @State private var choosing = false

    var body: some View {
        Button("选时间") { choosing = true }
            .accessibilityIdentifier("review.chooseClock")
            .sheet(isPresented: $choosing) {
                ClockOnDay(missing: missing, calendar: row.draft.due.calendar) { time in
                    choosing = false
                    row.resolveTime(time)
                }
            }
        Button("只记\(missing.dayName)（全天）") { row.resolveTime(nil) }
            .accessibilityHint("保存为全天，不安排提醒")
            .accessibilityIdentifier("review.keepDay")
    }
}

private struct ClockOnDay: View {
    let missing: MissingTime
    let calendar: Calendar
    let choose: (Date) -> Void
    @State private var clock: Date
    @Environment(\.dismiss) private var dismiss

    init(missing: MissingTime, calendar: Calendar, choose: @escaping (Date) -> Void) {
        self.missing = missing
        self.calendar = calendar
        self.choose = choose
        _clock = State(initialValue: missing.pickerStart(in: calendar))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(Due.format(missing.day, zone: calendar.timeZone, pattern: "yyyy年M月d日 EEEE"))
                    .font(.subheadline).foregroundStyle(.secondary)
                DatePicker("钟点", selection: $clock, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                    .environment(\.timeZone, calendar.timeZone)
            }
            .navigationTitle(missing.dayName + missing.period).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") { choose(clock) }.accessibilityIdentifier("review.confirmClock")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
