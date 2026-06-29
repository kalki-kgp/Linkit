import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, devices, transfers, phone, network, diagnostics, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .devices: return "Devices"
        case .transfers: return "Transfers"
        case .phone: return "Phone & Audio"
        case .network: return "Network"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }

    /// Short caption shown under the page title in the detail header.
    var subtitle: String {
        switch self {
        case .general: return "Manage Linkit's general settings."
        case .appearance: return "Make Linkit feel like yours."
        case .devices: return "Your paired Android device."
        case .transfers: return "Where received files land and recent activity."
        case .phone: return "Place and control calls from your Mac."
        case .network: return "Listening address and port."
        case .diagnostics: return "Status, reports, and updates."
        case .about: return "About Linkit."
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        case .devices: return "iphone"
        case .transfers: return "arrow.up.arrow.down"
        case .phone: return "phone.fill"
        case .network: return "network"
        case .diagnostics: return "waveform.path.ecg"
        case .about: return "info.circle.fill"
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection, accent: prefs.accent)
                .frame(width: 224)
            Divider().opacity(0.35)
            SettingsDetail(model: model, prefs: prefs, section: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
        .ignoresSafeArea(.all, edges: .top)
        .onAppear { model.onRefresh() }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    let accent: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            VisualEffectBackground(material: .sidebar, blending: .behindWindow)

            VStack(alignment: .leading, spacing: 0) {
                brandHeader
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(SettingsSection.allCases) { section in
                            SidebarRow(
                                section: section,
                                accent: accent,
                                isSelected: selection == section
                            ) { selection = section }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(
                    colors: [accent, accent.opacity(0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "link")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Linkit").font(.system(size: 15, weight: .bold))
                Text("Secure. Simple. Effortless.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 40)
        .padding(.bottom, 16)
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let accent: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: [accent, accent.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Detail

private struct SettingsDetail: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences
    let section: SettingsSection

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blending: .behindWindow)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(.system(size: 22, weight: .bold))
                    Text(section.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.top, 38)
                .padding(.bottom, 18)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        content
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                footer
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettings(model: model, prefs: prefs)
        case .appearance: AppearanceSettings(prefs: prefs)
        case .devices: DeviceSettings(model: model, prefs: prefs)
        case .transfers: TransferSettings(model: model, prefs: prefs)
        case .phone: PhoneSettings(model: model, prefs: prefs)
        case .network: NetworkSettings(model: model, prefs: prefs)
        case .diagnostics: DiagnosticsSettings(model: model, prefs: prefs)
        case .about: AboutSettings(model: model, prefs: prefs)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 10))
                .foregroundStyle(prefs.accent)
            Text("Thanks for using Linkit")
                .font(.system(size: 11, weight: .medium))
            Text("· Made with care for a seamless experience.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text("v\(model.version)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }
}

// MARK: - Reusable building blocks

/// Translucent material backing for the SwiftUI window — the "liquid glass" base.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// An uppercase group label plus a translucent card holding the group's rows.
private struct SettingsGroup<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
        }
    }
}

/// Accent-tinted rounded icon tile used at the leading edge of every card row.
private struct IconTile: View {
    let icon: String
    let accent: Color
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(
                colors: [accent.opacity(0.95), accent.opacity(0.6)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// A card row with an icon tile, title/subtitle, and an arbitrary trailing control.
private struct CardRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let accent: Color
    var enabled: Bool = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: icon, accent: accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(enabled ? 1 : 0.55)
    }
}

/// A toggle row: `CardRow` with a switch tinted to the accent.
private struct ToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let accent: Color
    var enabled: Bool = true
    @Binding var isOn: Bool

    var body: some View {
        CardRow(icon: icon, title: title, subtitle: subtitle, accent: accent, enabled: enabled) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
                .disabled(!enabled)
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.leading, 56)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Group {
            SettingsGroup(label: "Startup") {
                ToggleRow(
                    icon: "power",
                    title: "Launch Linkit at login",
                    subtitle: model.launchAtLoginAvailable
                        ? "Automatically start Linkit when you log in to your Mac."
                        : "Available when running the packaged Linkit.app.",
                    accent: prefs.accent,
                    enabled: model.launchAtLoginAvailable,
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.onSetLaunchAtLogin($0) }
                    )
                )
            }

            SettingsGroup(label: "Clipboard") {
                ToggleRow(
                    icon: "doc.on.clipboard.fill",
                    title: "Sync clipboard text to Android",
                    subtitle: "Copy on your Mac, paste on the paired Android device. Android → Mac sync only works while the Android app is open (an OS privacy limit).",
                    accent: prefs.accent,
                    isOn: Binding(
                        get: { model.clipboardSyncEnabled },
                        set: { model.onSetClipboardSync($0) }
                    )
                )
            }

            SettingsGroup(label: "Notifications") {
                ToggleRow(
                    icon: "bell.badge.fill",
                    title: "Notify when a transfer is received",
                    subtitle: "Get notified when a device sends you a file. Banners require the packaged Linkit.app and notification permission.",
                    accent: prefs.accent,
                    isOn: $prefs.notifyOnTransferComplete
                )
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @ObservedObject var prefs: Preferences

    /// Two-way bridge between the stored hex string and SwiftUI's `ColorPicker`.
    private var customColor: Binding<Color> {
        Binding(
            get: { prefs.accent },
            set: { prefs.accentColorHex = $0.toHexString() ?? Preferences.defaultAccentHex }
        )
    }

    private var isCustom: Bool {
        let current = prefs.accentColorHex.uppercased()
        return !LinkitAccent.presets.contains { $0.hex.uppercased() == current }
    }

    private var currentName: String {
        if isCustom { return "Custom (\(prefs.accentColorHex.uppercased()))" }
        return LinkitAccent.presets.first { $0.hex.uppercased() == prefs.accentColorHex.uppercased() }?.name
            ?? prefs.accentColorHex.uppercased()
    }

    var body: some View {
        Group {
            SettingsGroup(label: "Accent color") {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                        ForEach(LinkitAccent.presets) { preset in
                            SwatchButton(
                                color: preset.color,
                                isSelected: preset.hex.uppercased() == prefs.accentColorHex.uppercased(),
                                action: { prefs.accentColorHex = preset.hex }
                            )
                            .help(preset.name)
                        }
                    }
                    Divider().opacity(0.5)
                    ColorPicker(selection: customColor, supportsOpacity: false) {
                        Text("Custom color").font(.system(size: 13, weight: .medium))
                    }
                    HStack {
                        Text(currentName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if prefs.accentColorHex.uppercased() != Preferences.defaultAccentHex.uppercased() {
                            Button("Reset") { prefs.accentColorHex = Preferences.defaultAccentHex }
                                .controlSize(.small)
                        }
                    }
                }
                .padding(14)
            }

            SettingsGroup(label: "Preview") {
                AccentPreview(accent: prefs.accent)
                    .padding(14)
            }

            SettingsGroup(label: "Window theme") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $prefs.appearance) {
                        ForEach(LinkitAppearancePreference.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text("Applies to the menu-bar popover and this window. The menu-bar icon follows your system tint.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }
}

private struct SwatchButton: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(height: 30)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0.0), lineWidth: 2)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(isSelected ? 1 : 0)
                )
                .padding(2)
        }
        .buttonStyle(.plain)
    }
}

private struct AccentPreview: View {
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: "link", accent: accent, size: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text("Connected to Pixel")
                    .font(.system(size: 13, weight: .medium))
                ProgressView(value: 0.6).tint(accent)
            }
            Spacer()
            Text("Call")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent))
        }
    }
}

// MARK: - Devices

private struct DeviceSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Group {
            SettingsGroup(label: "Paired") {
                if model.devices.isEmpty {
                    CardRow(icon: "iphone.slash", title: "No devices paired yet",
                            subtitle: "Show the pairing QR below and scan it from the Linkit app.",
                            accent: prefs.accent) { EmptyView() }
                } else {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { RowDivider() }
                        DeviceRowView(device: device, model: model, accent: prefs.accent)
                    }
                }
            }

            SettingsGroup(label: "Pairing") {
                CardRow(icon: "qrcode", title: "Show Pairing QR",
                        subtitle: "Scan from the Linkit app on your Android phone. Pairing is one-time and stays local.",
                        accent: prefs.accent) {
                    Button("Show QR") { model.onShowQR() }
                        .buttonStyle(.borderedProminent)
                        .tint(prefs.accent)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct DeviceRowView: View {
    let device: SettingsDeviceRow
    @ObservedObject var model: SettingsViewModel
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            IconTile(icon: "iphone", accent: device.isConnected ? accent : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.isConnected ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(device.isConnected ? "Connected" : "Paired, offline")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if let battery = device.batteryPercent {
                        Text("· \(battery)%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if device.isConnected {
                Button("Disconnect") { model.onDisconnect(device.id) }
                    .controlSize(.small)
            }
            Button(role: .destructive) { model.onForget(device.id) } label: {
                Text("Forget")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Transfers

private struct TransferSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Group {
            SettingsGroup(label: "Drop folder") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        IconTile(icon: "folder.fill", accent: prefs.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Received files").font(.system(size: 13, weight: .medium))
                            Text(model.dropFolderPath)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                    }
                    HStack {
                        Button("Change…") { model.onChangeDropFolder() }
                        if model.dropFolderIsCustom {
                            Button("Reset") { model.onResetDropFolder() }
                        }
                        Spacer()
                        Button("Reveal") { model.onRevealDropFolder() }
                        Button("Open") { model.onOpenDropFolder() }
                    }
                    .controlSize(.small)
                    Text("A new save location takes effect after Linkit relaunches.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            SettingsGroup(label: "Recent transfers") {
                if model.recentTransfers.isEmpty {
                    CardRow(icon: "tray", title: "No transfers yet",
                            subtitle: "Files you receive will show up here.",
                            accent: prefs.accent) { EmptyView() }
                } else {
                    ForEach(Array(model.recentTransfers.prefix(10).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        let fileURL = row.savedPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                        CardRow(icon: "doc.fill", title: row.filename, subtitle: row.status,
                                accent: prefs.accent) {
                            if row.savedPath != nil {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .overlay(FileDragOverlay(url: fileURL) {
                            if let path = row.savedPath { model.onOpenRecent(path) }
                        })
                    }
                }
            }

            SettingsGroup(label: "Log") {
                CardRow(icon: "doc.text.fill", title: "Transfer log",
                        subtitle: "Detailed debug log of every transfer.",
                        accent: prefs.accent) {
                    Button("Open") { model.onOpenLog() }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Phone & Audio

private struct PhoneSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Group {
            SettingsGroup(label: "Phone control") {
                CardRow(icon: "phone.fill", title: "Call control",
                        subtitle: "Place, answer, decline, and hang up Android calls from the Mac. Call audio stays on the phone.",
                        accent: prefs.accent) {
                    Text(model.phoneStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Group {
            SettingsGroup(label: "Listening") {
                CardRow(icon: "antenna.radiowaves.left.and.right", title: "Address",
                        accent: prefs.accent) {
                    Text("\(model.localIP):\(model.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsGroup(label: "Port") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        IconTile(icon: "number", accent: prefs.accent)
                        Text("Custom port").font(.system(size: 13, weight: .medium))
                        Spacer()
                        TextField("Port", value: $prefs.listenPort, format: .number.grouping(.never))
                            .frame(width: 110)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Set to 0 to use the default (52718). Both devices must agree on the port; a change takes effect after Linkit relaunches.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }

            if model.canRelaunch {
                SettingsGroup(label: "Apply") {
                    CardRow(icon: "arrow.clockwise", title: "Relaunch Linkit",
                            subtitle: "Restart now to apply a new port or drop folder.",
                            accent: prefs.accent) {
                        Button("Relaunch") { model.onRelaunch() }
                            .buttonStyle(.borderedProminent)
                            .tint(prefs.accent)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Group {
            SettingsGroup(label: "Status") {
                VStack(spacing: 0) {
                    DiagRow(label: "Receiving on", value: "\(model.localIP):\(model.port)", mono: true)
                    RowDivider()
                    DiagRow(label: "Trusted devices", value: "\(model.trustedCount)")
                    RowDivider()
                    DiagRow(label: "Drop folder", value: model.dropFolderPath, truncate: true)
                    RowDivider()
                    DiagRow(label: "Log file", value: model.logPath, truncate: true)
                }
            }

            SettingsGroup(label: "Report") {
                CardRow(icon: "doc.on.doc.fill", title: "Diagnostics report",
                        subtitle: "Copy a full status snapshot for issue reports.",
                        accent: prefs.accent) {
                    HStack(spacing: 8) {
                        Button("Refresh") { model.onRefresh() }
                            .controlSize(.small)
                        Button("Copy") { model.onCopyReport() }
                            .buttonStyle(.borderedProminent)
                            .tint(prefs.accent)
                            .controlSize(.small)
                    }
                }
            }

            SettingsGroup(label: "Updates") {
                CardRow(icon: "arrow.down.circle.fill", title: "Version \(model.version) (\(model.build))",
                        subtitle: "Check GitHub Releases for a newer build.",
                        accent: prefs.accent) {
                    Button("Check…") { model.onCheckUpdates() }
                        .buttonStyle(.borderedProminent)
                        .tint(prefs.accent)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct DiagRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var truncate: Bool = false

    var body: some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer(minLength: 16)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(truncate ? .middle : .tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - About

private struct AboutSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [prefs.accent, prefs.accent.opacity(0.6)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 76, height: 76)
                .overlay(
                    Image(systemName: "link")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                )
            Text("Linkit").font(.system(size: 22, weight: .semibold))
            Text("Version \(model.version) (\(model.build))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("A private link between one Mac and one Android phone. Files, clipboard, links, and phone-call control move directly over your local network — no accounts, no cloud, no relay.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Link("View on GitHub", destination: URL(string: "https://github.com/kalki-kgp/Linkit")!)
                .font(.system(size: 12))
                .tint(prefs.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }
}
