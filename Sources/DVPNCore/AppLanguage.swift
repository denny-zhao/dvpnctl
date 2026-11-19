import Foundation

enum AppLanguage: String, Codable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

enum LanguageChoice: String, CaseIterable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    private static let key = "interface-language"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }

    func resolve(_ preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: rawValue) { return explicit }
        for identifier in preferredLanguages {
            let parts = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })
            if parts.first == "en" { return .english }
            if parts.first == "zh", !parts.dropFirst().contains("hant") {
                if parts.contains("hans") || !parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) {
                    return .simplifiedChinese
                }
            }
        }
        return .english
    }

    var title: AppText {
        switch self {
        case .system: return AppText("System Default", "跟随系统")
        case .english: return AppText("English")
        case .simplifiedChinese: return AppText("简体中文")
        }
    }
}

struct AppText: Codable, Equatable {
    let english: String
    let chinese: String

    init(_ english: String, _ chinese: String? = nil) {
        self.english = english
        self.chinese = chinese ?? english
    }

    func render(_ language: AppLanguage) -> String {
        language == .simplifiedChinese ? chinese : english
    }

    func appending(_ other: AppText) -> AppText {
        AppText(english + other.english, chinese + other.chinese)
    }

    static func from(_ error: Error) -> AppText {
        (error as? VPNError)?.message ?? AppText(error.localizedDescription)
    }
}
