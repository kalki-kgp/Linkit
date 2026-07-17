import Foundation

/// Machine-readable health of a single Linkit feature, shared over the wire so each device can
/// render the *other* device's self-reported feature health next to its own — one synced source
/// of truth instead of two apps guessing at each other's state.
public enum FeatureState: String, Codable, Equatable {
    /// Enabled and working.
    case on
    /// Deliberately off (user toggle).
    case off
    /// The user wants it on, but it is broken — a missing permission or an unbound service.
    case attention
    /// Not available on this device / OS.
    case unsupported
}

public struct FeatureStatus: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let state: FeatureState
    public let detail: String

    public init(id: String, title: String, state: FeatureState, detail: String) {
        self.id = id
        self.title = title
        self.state = state
        self.detail = detail
    }
}

/// Well-known feature ids shared with the Android app. Keep in lockstep with
/// `AndroidFeatureStatus` in the Kotlin sources.
public enum MacFeatureID {
    public static let clipboardSync = "clipboard_sync"
    public static let launchAtLogin = "launch_at_login"
    public static let transferNotifications = "transfer_notifications"
    public static let receiver = "receiver"

    /// Feature ids the Mac can re-drive on the phone's behalf via a `feature_resolve` action.
    /// The phone only claims success for these; anything else is rejected so it can't falsely
    /// report "asked your Mac to fix it" for a feature the Mac would silently ignore.
    public static let resolvable: Set<String> = [transferNotifications]
}
