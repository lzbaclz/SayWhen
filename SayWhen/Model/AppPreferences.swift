import Foundation
import SwiftData

enum DefaultAdvance: Equatable {
    case previousEvening
    case minutes(Int)

    static let presets = [15, 30, 60, 120]

    static func label(minutes: Int) -> String {
        minutes.isMultiple(of: 60) ? "提前 \(minutes / 60) 小时" : "提前 \(minutes) 分钟"
    }

    var label: String {
        switch self {
        case .previousEvening: "前一天晚上 20:00"
        case .minutes(let minutes): Self.label(minutes: minutes)
        }
    }

    func time(for due: Due) -> Date? {
        guard due.kind != .none else { return nil }
        let calendar = due.calendar
        let midnight = calendar.startOfDay(for: due.date)
        switch self {
        case .previousEvening:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: midnight) else { return nil }
            return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: yesterday)
        case .minutes(let minutes):
            guard (0...Int(Int32.max)).contains(minutes) else { return nil }
            return calendar.date(byAdding: .minute, value: -minutes, to: due.kind == .allDay ? midnight : due.date)
        }
    }
}

enum SpeechLanguage: String, CaseIterable {
    case mandarin = "zh-CN"
    case english = "en-US"

    var label: String { self == .mandarin ? "普通话（可夹英文）" : "英语（美国）" }
}

struct AppPreferences: Equatable {
    var advance = DefaultAdvance.previousEvening
    var language = SpeechLanguage.mandarin
    var vocabulary = ""

    func validated() throws -> AppPreferences {
        if case .minutes(let minutes) = advance, !(1...Int(Int32.max)).contains(minutes) {
            throw PreferencesError.interval
        }
        let words = vocabulary.components(separatedBy: CharacterSet(charactersIn: "\n,，;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        guard unique.count <= 100, unique.allSatisfy({ $0.count <= 64 }) else { throw PreferencesError.words }
        var result = self
        result.vocabulary = unique.joined(separator: "\n")
        return result
    }
}

private enum PreferencesError: LocalizedError {
    case interval, words
    var errorDescription: String? {
        switch self {
        case .interval: "请输入有效的提前分钟数。"
        case .words: "最多可添加 100 个常用专名，每个不超过 64 个字符。"
        }
    }
}
enum SchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [SchemaV1.Item.self, Settings.self] }

    @Model final class Settings {
        @Attribute(.unique) var id: String
        var advanceMinutes: Int?
        var language: String
        var vocabulary: String

        init() {
            id = "local"
            language = SpeechLanguage.mandarin.rawValue
            vocabulary = ""
        }

        var value: AppPreferences {
            AppPreferences(advance: advanceMinutes.map(DefaultAdvance.minutes) ?? .previousEvening,
                           language: SpeechLanguage(rawValue: language) ?? .mandarin, vocabulary: vocabulary)
        }

        func apply(_ preferences: AppPreferences) {
            if case .minutes(let count) = preferences.advance { advanceMinutes = count }
            else { advanceMinutes = nil }
            language = preferences.language.rawValue
            vocabulary = preferences.vocabulary
        }
    }
}

enum LocalDatabase {
    static func open(configuration: ModelConfiguration? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        return try ModelContainer(for: schema, migrationPlan: MigrationPlan.self,
                                  configurations: configuration ?? ModelConfiguration(schema: schema, cloudKitDatabase: .none))
    }
}
