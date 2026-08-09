import Foundation
import GitHubKit

/// The `UserDefaults` keys the app reads, in one place.
///
/// M6 needs exactly one of them: the per-repository tag pattern map. The Settings window
/// that writes it is M7 — the plan keeps it there deliberately, because the map has a
/// sensible default (`v*`) and M6 is demoable against repositories that use it
/// (IMPLEMENTATION_PLAN §7). Until the editor exists, the map can be set by hand:
///
/// ```sh
/// defaults write com.jankuca.PRStackMonitor tagPatterns \
///     -dict "acme/billing" "release-*" "acme/web" "v*"
/// ```
enum AppDefaults {
    static let tagPatternsKey = "tagPatterns"

    /// The repository → glob map, with anything unreadable ignored rather than fatal.
    ///
    /// `defaults write` can put any plist value under this key, including a value that is
    /// not a dictionary of strings. A wrong type there must cost the user their custom
    /// patterns, not the app's release tracking: entries that are not `String: String` are
    /// dropped, and every repository without a usable entry falls back to `v*`.
    static func tagPatterns(_ defaults: UserDefaults = .standard) -> TagPatterns {
        guard let stored = defaults.dictionary(forKey: tagPatternsKey) else { return .standard }
        var patterns: [String: String] = [:]
        for (repository, value) in stored {
            guard let pattern = value as? String else { continue }
            patterns[repository] = pattern
        }
        return TagPatterns(patterns)
    }
}
