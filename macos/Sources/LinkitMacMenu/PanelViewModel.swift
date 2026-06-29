import Foundation

/// A row in the popover's "recent transfers" list.
struct RecentTransferRow: Identifiable {
    let id: String
    let filename: String
    let status: String
    let savedPath: String?
    let direction: RecentTransferDirection
}

enum RecentTransferDirection {
    case incoming
    case outgoing
    case unknown
}

/// A mirrored Android notification kept for the Settings → Notifications history list.
struct MirroredNotificationRow: Identifiable {
    let id: String
    let title: String
    let body: String
    let appName: String
    let receivedAt: Date
}

/// How the phone-control row should present itself in the panel.
struct PanelPhoneState {
    var statusText: String = "Waiting for Android permission"
    var isRinging: Bool = false
    var isActive: Bool = false
    var callerLabel: String? = nil

    var hasCall: Bool { isRinging || isActive }
}

/// Live snapshot of an in-flight transfer for the panel's inline progress strip.
struct PanelTransfer {
    var title: String
    var detail: String
    var progress: Double?
    var isOutgoing: Bool
    var isActive: Bool
    var didFail: Bool
}

/// Observable bridge between the AppKit delegate (which owns all logic) and the
/// SwiftUI popover. The delegate pushes state in via ``apply(...)`` whenever it
/// previously rebuilt the menu, and the view calls back through the action
/// closures, which the delegate wires to its existing handlers.
final class PanelViewModel: ObservableObject {
    // MARK: State
    @Published var localAddress: String = ""
    @Published var isConnected: Bool = false
    @Published var connectedDeviceName: String? = nil
    @Published var pairedDeviceName: String? = nil
    @Published var batteryPercent: Int? = nil
    @Published var hasAndroidTarget: Bool = false
    @Published var clipboardSyncEnabled: Bool = true
    @Published var phone = PanelPhoneState()
    @Published var recentTransfers: [RecentTransferRow] = []
    @Published var activeTransfer: PanelTransfer? = nil

    // MARK: Actions (wired by the delegate)
    var onSendFile: () -> Void = {}
    var onSendClipboard: () -> Void = {}
    var onOpenLink: () -> Void = {}
    var onToggleClipboardSync: () -> Void = {}
    var onShowQR: () -> Void = {}
    var onReconnect: () -> Void = {}
    var onCallNumber: () -> Void = {}
    var onAnswer: () -> Void = {}
    var onDecline: () -> Void = {}
    var onHangUp: () -> Void = {}
    var onOpenDropFolder: () -> Void = {}
    var onOpenRecent: (String) -> Void = { _ in }
    var onCancelTransfer: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
}
