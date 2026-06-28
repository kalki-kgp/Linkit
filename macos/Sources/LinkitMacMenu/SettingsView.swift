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

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .devices: return "iphone"
        case .transfers: return "arrow.up.arrow.down"
        case .phone: return "phone"
        case .network: return "network"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(selection.title)
        }
        .frame(minWidth: 700, minHeight: 460)
        .onAppear { model.onRefresh() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettings(model: model, prefs: prefs)
        case .appearance: AppearanceSettings(prefs: prefs)
        case .devices: DeviceSettings(model: model)
        case .transfers: TransferSettings(model: model)
        case .phone: PhoneSettings(model: model)
        case .network: NetworkSettings(model: model, prefs: prefs)
        case .diagnostics: DiagnosticsSettings(model: model)
        case .about: AboutSettings(model: model)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Linkit at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.onSetLaunchAtLogin($0) }
                ))
                .disabled(!model.launchAtLoginAvailable)
                if !model.launchAtLoginAvailable {
                    Text("Available when running the packaged Linkit.app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Clipboard") {
                Toggle("Sync clipboard text to Android", isOn: Binding(
                    get: { model.clipboardSyncEnabled },
                    set: { model.onSetClipboardSync($0) }
                ))
                Text("When on, text you copy on the Mac is pushed to the paired Android device. Android → Mac sync only works while the Android app is open (an OS privacy limit).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Notifications") {
                Toggle("Notify when a transfer is received", isOn: $prefs.notifyOnTransferComplete)
                Text("Banners require the packaged Linkit.app and notification permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        Form {
            Section("Accent color") {
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
                .padding(.vertical, 4)

                ColorPicker("Custom color", selection: customColor, supportsOpacity: false)

                HStack {
                    Text(isCustom ? "Custom (\(prefs.accentColorHex.uppercased()))" : (LinkitAccent.presets.first { $0.hex.uppercased() == prefs.accentColorHex.uppercased() }?.name ?? prefs.accentColorHex.uppercased()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if prefs.accentColorHex.uppercased() != Preferences.defaultAccentHex.uppercased() {
                        Button("Reset") { prefs.accentColorHex = Preferences.defaultAccentHex }
                            .controlSize(.small)
                    }
                }
            }

            Section("Preview") {
                AccentPreview(accent: prefs.accent)
            }

            Section("Theme") {
                Picker("Window theme", selection: $prefs.appearance) {
                    ForEach(LinkitAppearancePreference.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("Changes apply to the menu-bar popover and this Settings window. The menu-bar icon follows your system tint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
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
            Image(systemName: "link.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(accent)
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
        .padding(.vertical, 4)
    }
}

// MARK: - Devices

private struct DeviceSettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section("Paired") {
                if model.devices.isEmpty {
                    Text("No devices paired yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.devices) { device in
                        DeviceRowView(device: device, model: model)
                    }
                }
            }
            Section {
                Button {
                    model.onShowQR()
                } label: {
                    Label("Show Pairing QR", systemImage: "qrcode")
                }
            } footer: {
                Text("Scan from the Linkit app on your Android phone. Pairing is one-time and stays local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DeviceRowView: View {
    let device: SettingsDeviceRow
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .foregroundStyle(device.isConnected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.isConnected ? Color.green : Color.secondary)
                        .frame(width: 6, height: 6)
                    Text(device.isConnected ? "Connected" : "Paired, offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let battery = device.batteryPercent {
                        Text("· \(battery)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if device.isConnected {
                Button("Disconnect") { model.onDisconnect(device.id) }
                    .controlSize(.small)
            }
            Button(role: .destructive) { model.onForget(device.id) } label: {
                Text("Forget")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Transfers

private struct TransferSettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section("Drop folder") {
                LabeledContent("Location") {
                    Text(model.dropFolderPath)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Change…") { model.onChangeDropFolder() }
                    if model.dropFolderIsCustom {
                        Button("Reset to Default") { model.onResetDropFolder() }
                    }
                    Spacer()
                    Button("Reveal") { model.onRevealDropFolder() }
                    Button("Open") { model.onOpenDropFolder() }
                }
                Text("A new save location takes effect after Linkit relaunches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recent transfers") {
                if model.recentTransfers.isEmpty {
                    Text("No transfers yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentTransfers.prefix(10)) { row in
                        Button {
                            if let path = row.savedPath { model.onOpenRecent(path) }
                        } label: {
                            HStack {
                                Text(row.filename).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(row.status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(row.savedPath == nil)
                    }
                }
            }

            Section {
                Button("Open Transfer Log") { model.onOpenLog() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Phone & Audio

private struct PhoneSettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section("Phone control") {
                LabeledContent("Status", value: model.phoneStatus)
                Text("Place, answer, decline, and hang up Android calls from the Mac. Call audio stays on the phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Network

private struct NetworkSettings: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Listening") {
                LabeledContent("Address", value: "\(model.localIP):\(model.port)")
            }
            Section("Port") {
                TextField("Port", value: $prefs.listenPort, format: .number.grouping(.never))
                    .frame(width: 120)
                Text("Set to 0 to use the default (52718). Both devices must agree on the port; a change takes effect after Linkit relaunches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canRelaunch {
                Section {
                    Button("Relaunch Linkit Now") { model.onRelaunch() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Receiving on", value: "\(model.localIP):\(model.port)")
                LabeledContent("Trusted devices", value: "\(model.trustedCount)")
                LabeledContent("Drop folder") {
                    Text(model.dropFolderPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("Log file") {
                    Text(model.logPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Section {
                HStack {
                    Button("Copy Diagnostics Report") { model.onCopyReport() }
                    Button("Refresh") { model.onRefresh() }
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: "\(model.version) (\(model.build))")
                Button("Check for Updates…") { model.onCheckUpdates() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettings: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
