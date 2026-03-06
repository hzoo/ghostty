import Foundation

enum ProductBrand {
    static let displayName =
        infoString("CFBundleDisplayName") ??
        infoString("CFBundleName") ??
        "Ghostty"

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty"
    static let notificationNamespace = infoString("GlossolaliaNotificationNamespace") ?? bundleIdentifier
    static let defaultsSuiteName = infoString("GlossolaliaDefaultsSuiteName") ?? bundleIdentifier

    static func namespaced(_ suffix: String) -> String {
        "\(notificationNamespace).\(suffix)"
    }

    static func updateFeedURL(channel: Ghostty.AutoUpdateChannel) -> String? {
        switch channel {
        case .tip:
            return infoString("GlossolaliaUpdateTipFeedURL") ??
                "https://tip.files.ghostty.dev/appcast.xml"
        case .stable:
            return infoString("GlossolaliaUpdateStableFeedURL") ??
                "https://release.files.ghostty.org/appcast.xml"
        }
    }

    static func releaseNotesURL(version: String, versionDash: String) -> URL? {
        templatedURL(
            "GlossolaliaReleaseNotesURLTemplate",
            replacements: [
                "version": version,
                "version-dash": versionDash,
                "slug": versionDash,
            ],
        )
    }

    static func compareURL(currentHash: String, newHash: String) -> URL? {
        templatedURL(
            "GlossolaliaCompareURLTemplate",
            replacements: [
                "current": currentHash,
                "new": newHash,
            ],
        )
    }

    static func commitURL(newHash: String) -> URL? {
        templatedURL(
            "GlossolaliaCommitURLTemplate",
            replacements: ["new": newHash],
        )
    }

    private static func templatedURL(
        _ key: String,
        replacements: [String: String],
    ) -> URL? {
        guard var template = infoString(key) else { return nil }
        for (token, value) in replacements {
            template = template.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return URL(string: template)
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
