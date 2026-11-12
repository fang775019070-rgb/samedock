import Foundation

private final class EchoDockLocalizationBundleToken: NSObject {}

enum L10n {
    /// AppleLanguages includes macOS's per-app language override. SameDock has
    /// no separate language preference; unsupported primary languages use English.
    static func language(for preferredLanguages: [String]) -> String {
        let primary = preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "en"
        return primary == "zh" || primary.hasPrefix("zh-") ? "zh-Hans" : "en"
    }

    private static let bundle: Bundle = {
        let resources = Bundle(for: EchoDockLocalizationBundleToken.self)
        let languages = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
        guard let path = resources.path(forResource: language(for: languages), ofType: "lproj"),
              let localized = Bundle(path: path) else { return resources }
        return localized
    }()

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
