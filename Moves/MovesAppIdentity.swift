import Foundation

/// Build-time identifiers shared by the app, its widgets, and the watch app.
///
/// The values come from `Config/Moves.xcconfig`, which derives every bundle ID, the
/// App Group, and the iCloud container from a single `MOVES_BUNDLE_ID_PREFIX`. The
/// same settings fill each target's entitlements and `Info.plist`, so reading them
/// back here means the prefix is declared exactly once: a fork can re-sign the whole
/// app under its own Apple Developer account by overriding one build setting, with no
/// source changes.
///
/// This type is compiled into every target that needs a shared container. Each target
/// reads its own `Info.plist`, which is why the App Group cannot simply be derived
/// from `Bundle.main.bundleIdentifier` — in the widget and watch processes that is the
/// extension's identifier, not the app's.
enum MovesAppIdentity {
    /// App Group container shared by all Moves targets.
    ///
    /// Matches `com.apple.security.application-groups` in every entitlements file.
    static let appGroupIdentifier = requiredValue(forKey: "MovesAppGroupIdentifier")

    /// Private CloudKit and iCloud Drive container.
    ///
    /// Only the main app declares this key, so only the app may read it. Access from
    /// an extension traps.
    static let cloudKitContainerIdentifier = requiredValue(forKey: "MovesCloudKitContainerIdentifier")

    /// Bundle identifier of the running target.
    ///
    /// Used as the logging subsystem and as the prefix for `BGTaskScheduler`
    /// identifiers, which `Info.plist` declares as
    /// `$(PRODUCT_BUNDLE_IDENTIFIER).<suffix>`.
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "Moves"

    /// Reads a required identifier from the running target's `Info.plist`.
    ///
    /// A missing value means the `$(MOVES_…)` entry was dropped from the plist, which
    /// would otherwise fail later and silently as an unreachable shared container, so
    /// fail immediately instead.
    ///
    /// - Parameter key: `Info.plist` key holding the identifier.
    /// - Returns: The non-empty identifier.
    private static func requiredValue(forKey key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else {
            preconditionFailure("\(key) missing from Info.plist; see Config/Moves.xcconfig")
        }
        return value
    }
}
