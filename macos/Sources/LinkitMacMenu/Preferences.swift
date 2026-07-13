import Foundation

/// How the menu-bar status icon is drawn.
enum LinkitMenuBarIconStyle: String, CaseIterable, Identifiable {
    /// Status-aware animated icon (paired, transferring, success, error).
    case automatic
    /// Static monochrome template glyph that follows the system menu-bar tint.
    case monochrome

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Status-aware (animated)"
        case .monochrome: return "Monochrome"
        }
    }
}

/// Appearance override for Linkit's own windows (popover + settings).
enum LinkitAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// `UserDefaults`-backed user preferences for the menu-bar app.
///
/// This is the first persistence layer in `LinkitMacMenu` — before it, the app
/// kept everything in transient delegate state. Keys live under the `pref.`
/// namespace so they don't collide with anything `LinkitMacCore` stores.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let clipboardSync = "pref.clipboardSyncEnabled"
        static let appearance = "pref.appearance"
        static let iconStyle = "pref.menuBarIconStyle"
        static let showBatteryInIcon = "pref.showBatteryInIcon"
        static let notifyOnTransfer = "pref.notifyOnTransferComplete"
        static let notifyOnConnect = "pref.notifyOnConnect"
        static let listenPort = "pref.listenPort"
        static let dropFolderBookmark = "pref.dropFolderBookmark"
        static let accentColor = "pref.accentColorHex"
        static let lastUpdateCheck = "pref.lastUpdateCheck"
    }

    /// Default primary accent — the original amber the app shipped with.
    static let defaultAccentHex = "#D16B1F"

    /// Whether Mac → Android clipboard text sync is running. Persisted so the
    /// choice survives relaunch.
    @Published var clipboardSyncEnabled: Bool {
        didSet { defaults.set(clipboardSyncEnabled, forKey: Key.clipboardSync) }
    }

    @Published var appearance: LinkitAppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// Primary accent color for Linkit's own UI, stored as `#RRGGBB`. Read as a
    /// SwiftUI `Color` via the `accent` extension in `AccentColor.swift`.
    @Published var accentColorHex: String {
        didSet { defaults.set(accentColorHex, forKey: Key.accentColor) }
    }

    @Published var menuBarIconStyle: LinkitMenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: Key.iconStyle) }
    }

    @Published var showBatteryInIcon: Bool {
        didSet { defaults.set(showBatteryInIcon, forKey: Key.showBatteryInIcon) }
    }

    @Published var notifyOnTransferComplete: Bool {
        didSet { defaults.set(notifyOnTransferComplete, forKey: Key.notifyOnTransfer) }
    }

    @Published var notifyOnConnect: Bool {
        didSet { defaults.set(notifyOnConnect, forKey: Key.notifyOnConnect) }
    }

    /// Custom listen port. `0` means "let the app pick its built-in default".
    @Published var listenPort: Int {
        didSet { defaults.set(listenPort, forKey: Key.listenPort) }
    }

    /// When the once-a-day background update check last ran. `nil` if never checked,
    /// so the first launch checks immediately.
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastUpdateCheck)
            } else {
                defaults.removeObject(forKey: Key.lastUpdateCheck)
            }
        }
    }

    /// Security-scoped bookmark for a user-chosen drop folder, or `nil` for the
    /// default `~/Downloads/Linkit Drop`.
    var dropFolderBookmark: Data? {
        get { defaults.data(forKey: Key.dropFolderBookmark) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.dropFolderBookmark)
            } else {
                defaults.removeObject(forKey: Key.dropFolderBookmark)
            }
            objectWillChange.send()
        }
    }

    private init() {
        self.defaults = .standard
        defaults.register(defaults: [
            Key.clipboardSync: true,
            Key.showBatteryInIcon: true,
            Key.notifyOnTransfer: true,
            Key.notifyOnConnect: true,
            Key.listenPort: 0,
            Key.accentColor: Preferences.defaultAccentHex,
        ])
        self.clipboardSyncEnabled = defaults.bool(forKey: Key.clipboardSync)
        self.appearance = LinkitAppearancePreference(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        self.accentColorHex = defaults.string(forKey: Key.accentColor) ?? Preferences.defaultAccentHex
        self.menuBarIconStyle = LinkitMenuBarIconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .automatic
        self.showBatteryInIcon = defaults.bool(forKey: Key.showBatteryInIcon)
        self.notifyOnTransferComplete = defaults.bool(forKey: Key.notifyOnTransfer)
        self.notifyOnConnect = defaults.bool(forKey: Key.notifyOnConnect)
        self.listenPort = defaults.integer(forKey: Key.listenPort)
    }
}
