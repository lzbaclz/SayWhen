import Foundation
import Speech
import CryptoKit

/// Only joins variants made of the same Latin letters. A similar-sounding Chinese word
/// or a different acronym must never be silently replaced with a vocabulary entry.
struct SpeechVocabulary {
    static let builtIns = ["CVPR", "ICCV", "ECCV", "NeurIPS", "ICML", "ICLR", "GitHub", "GitLab",
                           "Zoom", "Teams", "Figma", "Keynote", "PowerPoint", "Excel", "PDF", "PPT",
                           "API", "iOS", "Xcode", "TestFlight", "MacBook", "iPhone", "Wi-Fi"]
    let terms: [String]
    private let spellings: [String: String]
    private let pattern: NSRegularExpression?

    init(personal: String = "") {
        let custom = personal.components(separatedBy: CharacterSet(charactersIn: "\n,，;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen = Set<String>()
        terms = Array((custom + Self.builtIns).filter {
            !$0.isEmpty && $0.count <= 64 && seen.insert($0.lowercased()).inserted
        }.prefix(100))
        var alternatives = [String]()
        var canonical = [String: String]()
        for term in terms.sorted(by: { $0.count > $1.count }) {
            guard term.range(of: #"^[A-Za-z][A-Za-z0-9 .-]*$"#, options: .regularExpression) != nil else { continue }
            let key = Self.key(term)
            guard !key.isEmpty, canonical[key] == nil else { continue }
            canonical[key] = term
            let isInitialism = term == term.uppercased() || Self.builtIns.contains(term.uppercased())
            if isInitialism, (2...12).contains(term.count), term.allSatisfy(\.isLetter) {
                alternatives.append(term.map(String.init).joined(separator: #"[ .·\t]*"#))
            } else {
                let words = term.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
                alternatives.append(words.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s*"#))
            }
        }
        spellings = canonical
        pattern = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![a-zA-Z0-9])(?:" + alternatives.joined(separator: "|") + ")(?![a-zA-Z0-9])", options: .caseInsensitive)
    }

    private static func key(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    func display(_ text: String) -> String {
        guard let pattern else { return text }
        let output = NSMutableString(string: text)
        for hit in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let key = Self.key(output.substring(with: hit.range))
            if let term = spellings[key] { output.replaceCharacters(in: hit.range, with: term) }
        }
        return output as String
    }
}

/// Preparation is asynchronous: starting a recording never waits for model compilation.
@MainActor final class SpeechProfiles {
    static let shared = SpeechProfiles()
    private var attempted = Set<String>()
    private var ready: [String: SFSpeechLanguageModel.Configuration] = [:]
    private var cleanedLocales = Set<SpeechLanguage>()

    func configuration(language: SpeechLanguage, vocabulary: SpeechVocabulary) -> SFSpeechLanguageModel.Configuration? {
        let terms = vocabulary.terms
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let key = SHA256.hash(data: Data((["v1", "\(os.majorVersion).\(os.minorVersion)", language.rawValue] + terms).joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let cached = ready[key] { return cached }
        if attempted.insert(key).inserted {
            let clean = cleanedLocales.insert(language).inserted
            Task {
                if let config = await Task.detached(priority: .utility, operation: {
                    try? await Self.prepare(language: language, terms: terms, key: key, clean: clean)
                }).value { ready[key] = config }
            }
        }
        return nil
    }

    nonisolated private static func prepare(language: SpeechLanguage, terms: [String], key: String, clean: Bool) async throws -> SFSpeechLanguageModel.Configuration {
        let fm = FileManager.default
        let root = URL.cachesDirectory.appending(path: "SayWhenSpeech/" + language.rawValue, directoryHint: .isDirectory)
        let final = root.appending(path: key, directoryHint: .isDirectory)
        func config(_ folder: URL) -> SFSpeechLanguageModel.Configuration {
            SFSpeechLanguageModel.Configuration(languageModel: folder.appending(path: "model.bin"))
        }
        if clean, let prior = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for folder in prior where folder.lastPathComponent.count == 64 && folder != final {
                try? fm.removeItem(at: folder)
            }
        }
        if fm.fileExists(atPath: final.appending(path: "model.bin").path) { return config(final) }
        let staging = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) } }
        let data = SFCustomLanguageModelData(locale: Locale(identifier: language.rawValue),
                                             identifier: "local.saywhen.app.terms." + language.rawValue, version: key)
        for term in terms {
            data.insert(phraseCount: .init(phrase: term, count: 20))
            let uses = language == .mandarin ? ["关于" + term, term + "会议", term + "文档", "打开" + term] :
                                                ["open " + term, term + " meeting", term + " document"]
            for phrase in uses { data.insert(phraseCount: .init(phrase: phrase, count: 4)) }
        }
        let source = staging.appending(path: "phrases.bin")
        try await data.export(to: source)
        try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: source, configuration: config(staging))
        try fm.removeItem(at: source)
        try fm.moveItem(at: staging, to: final)
        return config(final)
    }
}
