import Foundation

struct SettingsDeviceRow: Identifiable {
    let id: String
    let name: String
    let platform: String
    let isConnected: Bool
    let batteryPercent: Int?
}

/// State + actions for the Settings window. The delegate populates the snapshot
/// fields via ``refreshSettings()`` and wires the action closures to its
/// existing handlers, mirroring ``PanelViewModel``.
final class SettingsViewModel: ObservableObject {
    // MARK: Snapshot
    @Published var launchAtLogin = false
    @Published var launchAtLoginAvailable = false
    @Published var clipboardSyncEnabled = true
    @Published var devices: [SettingsDeviceRow] = []
    @Published var localIP = ""
    @Published var port = ""
    @Published var dropFolderPath = ""
    @Published var dropFolderIsCustom = false
    @Published var logPath = ""
    @Published var trustedCount = 0
    @Published var recentTransfers: [RecentTransferRow] = []
    @Published var phoneStatus = ""
    @Published var version = ""
    @Published var build = ""

    // MARK: Actions
    var onSetLaunchAtLogin: (Bool) -> Void = { _ in }
    var onSetClipboardSync: (Bool) -> Void = { _ in }
    var onDisconnect: (String) -> Void = { _ in }
    var onForget: (String) -> Void = { _ in }
    var onShowQR: () -> Void = {}
    var onRevealDropFolder: () -> Void = {}
    var onOpenDropFolder: () -> Void = {}
    var onChangeDropFolder: () -> Void = {}
    var onResetDropFolder: () -> Void = {}
    var onRelaunch: () -> Void = {}
    var canRelaunch = false
    var onOpenRecent: (String) -> Void = { _ in }
    var onOpenLog: () -> Void = {}
    var onCheckUpdates: () -> Void = {}
    var onCopyReport: () -> Void = {}
    var onRefresh: () -> Void = {}
}
