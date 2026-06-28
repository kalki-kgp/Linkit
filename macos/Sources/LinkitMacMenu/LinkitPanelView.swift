import SwiftUI

private enum Brand {
    /// Primary accent — user-customizable in Settings → Appearance.
    static var amber: Color { Preferences.shared.accent }
    static let green = Color(red: 0.36, green: 0.55, blue: 0.34)
    static let panelWidth: CGFloat = 320
}

/// The menu-bar popover. A compact, status-first control surface that replaces
/// the old flat `NSMenu`.
struct LinkitPanelView: View {
    @ObservedObject var model: PanelViewModel
    // Re-render the popover when the user changes the accent color.
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.pairedDeviceName == nil {
                        unpaired
                    } else {
                        if let transfer = model.activeTransfer {
                            TransferStrip(transfer: transfer, onCancel: model.onCancelTransfer)
                        }
                        quickActions
                        clipboardSyncRow
                        PhoneRow(model: model)
                        if !model.recentTransfers.isEmpty {
                            recentTransfers
                        }
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: Brand.panelWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 11) {
            DeviceAvatar(name: model.pairedDeviceName, connected: model.isConnected)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.pairedDeviceName ?? "Linkit")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                StatusLine(model: model)
            }
            Spacer(minLength: 4)
            if let battery = model.batteryPercent {
                BatteryPill(percent: battery)
            }
            Button(action: model.onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Unpaired

    private var unpaired: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No phone paired yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Show the pairing QR here, then scan it from the Linkit app on your Android phone. Pairing happens once.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: model.onShowQR) {
                Label("Show Pairing QR", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            QuickActionTile(title: "Send File", systemImage: "doc.badge.plus", enabled: model.isConnected, action: model.onSendFile)
            QuickActionTile(title: "Clipboard", systemImage: "doc.on.clipboard", enabled: model.isConnected, action: model.onSendClipboard)
            QuickActionTile(title: "Open Link", systemImage: "link", enabled: model.isConnected, action: model.onOpenLink)
        }
    }

    private var clipboardSyncRow: some View {
        Toggle(isOn: Binding(
            get: { model.clipboardSyncEnabled },
            set: { _ in model.onToggleClipboardSync() }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Clipboard Sync")
                    .font(.system(size: 12, weight: .medium))
                Text("Copy on Mac → paste on Android")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(Brand.amber)
        .disabled(!model.isConnected)
    }

    // MARK: Recent transfers

    private var recentTransfers: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(model.recentTransfers.prefix(5)) { row in
                Button {
                    if let path = row.savedPath { model.onOpenRecent(path) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: row.direction == .outgoing ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                        Text(row.filename)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(row.status)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.savedPath == nil)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            if model.pairedDeviceName != nil {
                FooterButton(title: "Pairing QR", systemImage: "qrcode", action: model.onShowQR)
                FooterButton(title: "Drop Folder", systemImage: "folder", action: model.onOpenDropFolder)
            }
            Spacer()
            FooterButton(title: "Quit", systemImage: "power", action: model.onQuit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Status pieces

private struct StatusLine: View {
    @ObservedObject var model: PanelViewModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var dotColor: Color {
        if model.isConnected { return Brand.green }
        if model.pairedDeviceName != nil { return Brand.amber }
        return .secondary
    }

    private var text: String {
        if model.isConnected {
            return model.localAddress.isEmpty ? "Connected" : "Connected · \(model.localAddress)"
        }
        if model.pairedDeviceName != nil { return "Paired, offline" }
        return "Not paired"
    }
}

private struct DeviceAvatar: View {
    let name: String?
    let connected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(connected ? Brand.amber.opacity(0.16) : Color.secondary.opacity(0.14))
            Image(systemName: name == nil ? "iphone.slash" : "iphone")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(connected ? Brand.amber : Color.secondary)
        }
        .frame(width: 38, height: 38)
    }
}

private struct BatteryPill: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: batterySymbol)
                .font(.system(size: 10))
            Text("\(percent)%")
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private var batterySymbol: String {
        switch percent {
        case ..<15: return "battery.25"
        case ..<55: return "battery.50"
        default: return "battery.100"
        }
    }
}

// MARK: - Quick action tile

private struct QuickActionTile: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

// MARK: - Phone row

private struct PhoneRow: View {
    @ObservedObject var model: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "PHONE")
            HStack(spacing: 8) {
                Image(systemName: model.phone.isRinging ? "phone.arrow.down.left" : "phone")
                    .font(.system(size: 13))
                    .foregroundStyle(model.phone.hasCall ? Brand.amber : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.phone.callerLabel ?? phoneTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if model.phone.callerLabel != nil {
                        Text(phoneTitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if model.phone.isRinging {
                HStack(spacing: 8) {
                    SmallButton(title: "Answer", tint: Brand.green, action: model.onAnswer)
                    SmallButton(title: "Decline", tint: .red, action: model.onDecline)
                }
            } else if model.phone.isActive {
                SmallButton(title: "Hang Up", tint: .red, action: model.onHangUp)
            } else {
                SmallButton(title: "Call a Number…", tint: Brand.amber, enabled: model.isConnected, action: model.onCallNumber)
            }
        }
    }

    private var phoneTitle: String { model.phone.statusText }
}

// MARK: - Transfer strip

private struct TransferStrip: View {
    let transfer: PanelTransfer
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: transfer.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(transfer.didFail ? .red : Brand.amber)
                Text(transfer.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if transfer.isActive {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            if let progress = transfer.progress, transfer.isActive {
                ProgressView(value: progress).tint(Brand.amber)
            } else if transfer.isActive {
                ProgressView().tint(Brand.amber)
            }
            Text(transfer.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.amber.opacity(0.08)))
    }
}

// MARK: - Small shared pieces

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct SmallButton: View {
    let title: String
    let tint: Color
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
                .foregroundStyle(enabled ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

private struct FooterButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.amber))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
