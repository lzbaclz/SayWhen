import Foundation

enum ActionTitle {
    private static let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。；;、"))

    static func clean(_ text: String, personalCommand: Bool) -> String {
        var title = text.trimmingCharacters(in: trim)
        let verb = #"(?=告诉|转告|通知|联系|回复|提交|发送|准备|整理|检查|跟进|给|发|去|买|带|取|交)"#
        let subject = personalCommand ? #"^我(?:需要|要|得)?\s*"# : #"^我(?:需要|要|得)\s*"#
        title = title.replacingOccurrences(of: subject + verb, with: "", options: .regularExpression)
        return title.replacingOccurrences(of: #"(?<=\p{Han})(?=[A-Za-z])|(?<=[A-Za-z])(?=\p{Han})"#,
                                          with: " ", options: .regularExpression)
    }

    /// Old manually edited records are only changed when the owner taps the suggestion.
    static func suggestion(for title: String) -> String? {
        let prefix = #"^(?:今天|明天|后天)?(?:早晨|清晨|清早|早间|早上|上午|中午|下午|傍晚|晚上|晚间)\s*(?:提醒|通知|叫)我[，,、：:\s]+"#
        guard let range = title.range(of: prefix, options: .regularExpression) else { return nil }
        let action = clean(String(title[range.upperBound...]), personalCommand: true)
        return action.isEmpty ? nil : action
    }
}
