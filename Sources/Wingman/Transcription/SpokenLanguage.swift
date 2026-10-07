import Foundation
import NaturalLanguage

/// Languages the user can enable. Each must be supported by Parakeet (for the
/// live transcript) and by Apple's speech engine (for re-checking lines).
enum SpokenLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case spanish = "es"
    case portuguese = "pt"
    case french = "fr"
    case german = "de"
    case italian = "it"

    var id: String { rawValue }

    var name: String {
        Locale.current.localizedString(forLanguageCode: rawValue)?.capitalized ?? rawValue
    }

    var nlLanguage: NLLanguage { NLLanguage(rawValue: rawValue) }

    /// The regional variant for Apple's engine: the user's own region when it
    /// speaks this language, otherwise the most widely spoken variant.
    var locale: Locale {
        let region = Locale.current.region?.identifier
        if let region, Locale.current.language.languageCode?.identifier == rawValue {
            return Locale(identifier: "\(rawValue)-\(region)")
        }
        switch self {
        case .english: return Locale(identifier: "en-US")
        case .spanish: return Locale(identifier: "es-MX")
        case .portuguese: return Locale(identifier: "pt-BR")
        case .french: return Locale(identifier: "fr-FR")
        case .german: return Locale(identifier: "de-DE")
        case .italian: return Locale(identifier: "it-IT")
        }
    }

    static let defaults: Set<SpokenLanguage> = [.english, .spanish, .portuguese]

    /// A sensible main language: the first of the Mac's preferred languages
    /// that's enabled, else the first enabled one.
    static func preferredMain(among enabled: Set<SpokenLanguage>) -> SpokenLanguage {
        for identifier in Locale.preferredLanguages {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier,
               let language = SpokenLanguage(rawValue: code), enabled.contains(language) {
                return language
            }
        }
        return allCases.first(where: enabled.contains) ?? .english
    }
}
