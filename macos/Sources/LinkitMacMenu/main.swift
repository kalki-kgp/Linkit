import AppKit
import CoreImage
import LinkitMacCore
import Network
import ServiceManagement
import UserNotifications

private enum LinkitTransferPanelDirection {
    case androidToMac
    case macToAndroid
}

private struct LinkitTransferPanelState {
    let title: String
    let detail: String
    let progress: Double?
    let bytesDone: Int64
    let totalBytes: Int64
    let speedBytesPerSecond: Double
    let etaSeconds: TimeInterval?
    let direction: LinkitTransferPanelDirection
    let isActive: Bool
    let didFail: Bool
}

private struct AndroidPhoneState: Codable, Equatable {
    let state: String
    let number: String?
    let timestampMillis: Int64?
    let canAnswer: Bool?
    let canEnd: Bool?

    var displayName: String {
        number?.isEmpty == false ? number! : "Android call"
    }
}

final class LinkitMenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var app: LinkitReceiverApp?
    private var statusItem: NSStatusItem?
    private var statusIcon: StatusIconAnimator?
    private var qrWindow: NSWindow?
    private var retiredWindows: [NSWindow] = []
    private var diagnosticsWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var transferPanel: LinkitTransferPanel?
    private var currentTransfer: LinkitTransferPanelState?
    private var transferStartedAtById: [String: Date] = [:]
    private var activeOutgoingCancellation: LinkitCancellationToken?
    private var activeIncomingTransferId: String?
    private var resetStatusWorkItem: DispatchWorkItem?
    private var transferObservers: [NSObjectProtocol] = []
    private var deviceObserver: NSObjectProtocol?
    private var clipboardSyncTimer: Timer?
    private var clipboardSyncEnabled = false
    private var presenceTimer: Timer?
    private var presenceFailureCounts: [String: Int] = [:]
    private let presenceFailureThreshold = 3
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "Linkit.NetworkMonitor")
    private var networkRefreshWorkItem: DispatchWorkItem?
    private var lastNetworkPathSignature: String?
    private var lastClipboardText: String?
    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount
    private var lastTrustedSignature: String = ""
    private var lastConnectedSignature: String = ""
    private var currentPhoneState: AndroidPhoneState?
    private var incomingCallAlertVisible = false
    private var notificationCenter: UNUserNotificationCenter?
    private var appUpdater: MacAppUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureNotifications()
        appUpdater = try? MacAppUpdater()
        do {
            let receiver = try LinkitReceiverApp()
            self.app = receiver
            setupMenu()
            fputs("Linkit menu started. Look for 'Linkit' in the menu bar.\n", stderr)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try receiver.run()
                } catch {
                    DispatchQueue.main.async {
                        self.showError("Receiver failed: \(error)")
                    }
                }
            }
        } catch {
            showError("Could not start Linkit: \(error)")
        }
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: 38)
        installDropTarget(on: item.button)
        statusItem = item
        if let button = item.button {
            statusIcon = StatusIconAnimator(button: button)
        }
        refreshStatusButton()
        refreshMenu()
        startTransferObservers()
        startActionObserver()
        startDeviceObserver()
        startPresenceMonitor()
        startNetworkMonitor()
    }

    private func refreshStatusButton() {
        let trusted = app?.trustedDevices() ?? []
        let connected = app?.connectedDevices() ?? []
        let tooltip: String
        if connected.isEmpty {
            tooltip = trusted.isEmpty
                ? "Linkit not paired"
                : "Linkit paired with \(trusted.count), not connected"
        } else {
            tooltip = "Linkit connected to \(connected.count) device\(connected.count == 1 ? "" : "s")"
        }
        statusIcon?.setState(connected.isEmpty ? .disconnected : .connected, tooltip: tooltip)
    }

    private func checkForTrustChanges() {
        guard let app else { return }
        let devices = app.trustedDevices()
        let connected = app.connectedDevices()
        let trustedSignature = devices.map { "\($0.deviceId)|\($0.deviceName)" }.joined(separator: ",")
        let connectedSignature = connected.map { "\($0.deviceId)|\($0.host)|\($0.receivePort)" }.joined(separator: ",")

        if trustedSignature != lastTrustedSignature || connectedSignature != lastConnectedSignature {
            let hadTrustedSignature = !lastTrustedSignature.isEmpty
            let hadConnectedSignature = !lastConnectedSignature.isEmpty
            lastTrustedSignature = trustedSignature
            lastConnectedSignature = connectedSignature
            refreshStatusButton()
            refreshMenu()

            if hadTrustedSignature && !devices.isEmpty && !trustedSignature.isEmpty {
                announcePairing(devices.last)
            } else if !hadConnectedSignature && !connected.isEmpty {
                announceConnection(connected.last)
            }
        }
    }

    private func announcePairing(_ device: TrustedDevice?) {
        guard let device else { return }
        showTransientIcon(.success, tooltip: "Paired \(device.deviceName)")
        dismissPairingWindow()
    }

    private func announceConnection(_ device: ConnectedDevice?) {
        guard let device else { return }
        showTransientIcon(.success, tooltip: "Connected \(device.deviceName)")
        dismissPairingWindow()
    }

    private func dismissPairingWindow() {
        guard let window = qrWindow else { return }
        qrWindow = nil
        window.delegate = nil
        window.animationBehavior = .none
        window.orderOut(nil)

        retiredWindows.append(window)
        // Keep a short strong reference; dropping the window immediately after
        // orderOut can race AppKit teardown for the QR panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak window] in
            guard let self, let window else { return }
            self.retiredWindows.removeAll { $0 === window }
        }
    }

    private func refreshMenu() {
        guard let app else { return }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Receiving on \(LocalNetwork.bestPrivateIPv4()):\(app.configuration.port)", action: nil, keyEquivalent: ""))
        let trusted = app.trustedDevices()
        let connected = app.connectedDevices()
        let connectedIds = Set(connected.map(\.deviceId))
        if connected.isEmpty {
            let item = NSMenuItem(title: "No connected devices", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "Connected devices", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for device in connected {
                let item = NSMenuItem(title: "  \(device.deviceName) (\(device.platform))\(batterySuffix(device.batteryPercent))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                let refresh = NSMenuItem(title: "    Refresh \(device.deviceName) Status", action: #selector(refreshDeviceStatus(_:)), keyEquivalent: "")
                refresh.representedObject = device.deviceId
                menu.addItem(refresh)
            }
        }
        menu.addItem(NSMenuItem.separator())
        if trusted.isEmpty {
            let item = NSMenuItem(title: "No paired devices", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: "Paired devices", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for device in trusted {
                let state = connectedIds.contains(device.deviceId) ? "connected" : "paired, offline"
                let label = "  \(device.deviceName) (\(device.platform)) - \(state)"
                let pairedItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                pairedItem.isEnabled = false
                menu.addItem(pairedItem)
                if connectedIds.contains(device.deviceId) {
                    let disconnect = NSMenuItem(title: "    Disconnect \(device.deviceName)", action: #selector(disconnectDevice(_:)), keyEquivalent: "")
                    disconnect.representedObject = device.deviceId
                    menu.addItem(disconnect)
                }
                let forget = NSMenuItem(title: "    Forget \(device.deviceName)", action: #selector(forgetDevice(_:)), keyEquivalent: "")
                forget.representedObject = device.deviceId
                menu.addItem(forget)
            }
        }
        let androidTargets = connected.filter { $0.platform.lowercased() == "android" }
        menu.addItem(NSMenuItem(title: androidTargets.isEmpty ? "Android drop target: connect Android first" : "Drop files here to send to \(androidTargets[0].deviceName)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let sendClipboard = NSMenuItem(title: "Send Clipboard Text to Android", action: #selector(sendClipboardTextToAndroid), keyEquivalent: "c")
        sendClipboard.isEnabled = !androidTargets.isEmpty
        menu.addItem(sendClipboard)
        let openClipboardLink = NSMenuItem(title: "Open Clipboard Link on Android", action: #selector(openClipboardLinkOnAndroid), keyEquivalent: "u")
        openClipboardLink.isEnabled = !androidTargets.isEmpty
        menu.addItem(openClipboardLink)
        let clipboardSync = NSMenuItem(title: "Clipboard Text Sync: \(clipboardSyncEnabled ? "On" : "Off")", action: #selector(toggleClipboardSync), keyEquivalent: "")
        clipboardSync.isEnabled = !androidTargets.isEmpty || clipboardSyncEnabled
        menu.addItem(clipboardSync)
        menu.addItem(NSMenuItem.separator())
        let phoneHeader = NSMenuItem(title: phoneMenuTitle(), action: nil, keyEquivalent: "")
        phoneHeader.isEnabled = false
        menu.addItem(phoneHeader)
        let callNumber = NSMenuItem(title: "Call Number on Android...", action: #selector(callNumberOnAndroid), keyEquivalent: "")
        callNumber.isEnabled = !androidTargets.isEmpty
        menu.addItem(callNumber)
        let phoneState = currentPhoneState?.state.lowercased()
        let answerCall = NSMenuItem(title: "Answer Android Call", action: #selector(answerAndroidCall), keyEquivalent: "")
        answerCall.isEnabled = !androidTargets.isEmpty && phoneState == "ringing"
        menu.addItem(answerCall)
        let declineCall = NSMenuItem(title: "Decline Android Call", action: #selector(declineAndroidCall), keyEquivalent: "")
        declineCall.isEnabled = !androidTargets.isEmpty && phoneState == "ringing"
        menu.addItem(declineCall)
        let hangupCall = NSMenuItem(title: "Hang Up Android Call", action: #selector(hangupAndroidCall), keyEquivalent: "")
        hangupCall.isEnabled = !androidTargets.isEmpty && (phoneState == "ringing" || phoneState == "active")
        menu.addItem(hangupCall)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Show Pairing QR", action: #selector(showPairingQR), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Transfer Progress", action: #selector(showTransferProgress), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Open Linkit Drop", action: #selector(openDropFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Diagnostics", action: #selector(showDiagnostics), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Open Transfer Log", action: #selector(openTransferLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "Preferences", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: launchAtLoginMenuTitle(), action: #selector(toggleLaunchAtLogin), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(recentTransfersMenuItem(app: app))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshMenuAction), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit Linkit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func showPairingQR() {
        guard let app else { return }
        statusIcon?.setState(.pairing, tooltip: "Linkit pairing")

        let payload = app.pairingPayloadJSON()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 560))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.08, alpha: 1).cgColor

        let title = label("Linkit Pairing", frame: NSRect(x: 28, y: 510, width: 360, height: 26), size: 22, weight: .semibold)
        title.textColor = .white

        let subtitle = label("Scan this once. Transfers stay local and signed after pairing.", frame: NSRect(x: 28, y: 482, width: 380, height: 22), size: 13, weight: .regular)
        subtitle.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)

        let qrPanel = NSView(frame: NSRect(x: 60, y: 165, width: 320, height: 320))
        qrPanel.wantsLayer = true
        qrPanel.layer?.backgroundColor = NSColor.white.cgColor
        qrPanel.layer?.cornerRadius = 10

        let imageView = NSImageView(frame: NSRect(x: 18, y: 18, width: 284, height: 284))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = qrImage(from: payload, size: 284)
        qrPanel.addSubview(imageView)

        let details = label("IP \(LocalNetwork.bestPrivateIPv4())  Port \(app.configuration.port)", frame: NSRect(x: 28, y: 130, width: 380, height: 20), size: 13, weight: .medium)
        details.textColor = NSColor(calibratedRed: 0.45, green: 0.90, blue: 0.70, alpha: 1)

        let payloadField = NSTextField(wrappingLabelWithString: payload)
        payloadField.frame = NSRect(x: 28, y: 24, width: 384, height: 86)
        payloadField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        payloadField.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        payloadField.backgroundColor = .clear
        payloadField.isBordered = false
        payloadField.isSelectable = true

        content.addSubview(title)
        content.addSubview(subtitle)
        content.addSubview(details)
        content.addSubview(qrPanel)
        content.addSubview(payloadField)

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Linkit Pairing"
        window.delegate = self
        window.animationBehavior = .none
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        qrWindow = window
    }

    @objc private func showTransferProgress() {
        let state = currentTransfer ?? idleTransferState()
        showTransferPanel(state: state)
    }

    @objc private func openDropFolder() {
        guard let app else { return }
        NSWorkspace.shared.open(app.dropFolder)
    }

    @objc private func sendClipboardTextToAndroid() {
        guard let text = currentClipboardText(), !text.isEmpty else {
            showNonFatalError("Clipboard does not contain text.")
            return
        }
        sendActionToAndroid(type: "clipboard", text: text, successTooltip: "Clipboard sent to Android")
    }

    @objc private func openClipboardLinkOnAndroid() {
        guard let text = currentClipboardText(), let url = validatedWebURL(text) else {
            showNonFatalError("Clipboard does not contain an http or https URL.")
            return
        }
        sendActionToAndroid(type: "open_url", text: url.absoluteString, successTooltip: "Opened link on Android")
    }

    @objc private func toggleClipboardSync() {
        clipboardSyncEnabled.toggle()
        if clipboardSyncEnabled {
            lastClipboardChangeCount = NSPasteboard.general.changeCount
            lastClipboardText = currentClipboardText()
            clipboardSyncTimer?.invalidate()
            clipboardSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pollClipboardForSync()
            }
            showTransientIcon(.success, tooltip: "Clipboard sync on")
        } else {
            clipboardSyncTimer?.invalidate()
            clipboardSyncTimer = nil
            showTransientIcon(.connected, tooltip: "Clipboard sync off")
        }
        refreshMenu()
    }

    private func pollClipboardForSync() {
        guard clipboardSyncEnabled else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty, text != lastClipboardText else { return }
        guard text.utf8.count <= 128 * 1024 else { return }
        lastClipboardText = text
        sendActionToAndroid(type: "clipboard", text: text, successTooltip: "Clipboard synced")
    }

    private func sendActionToAndroid(type: String, text: String, successTooltip: String) {
        guard let app else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try app.sendActionToFirstAndroid(LinkitActionRequest(type: type, text: text))
                DispatchQueue.main.async {
                    self.showTransientIcon(.success, tooltip: successTooltip)
                }
            } catch {
                DispatchQueue.main.async {
                    if self.clipboardSyncEnabled {
                        self.clipboardSyncEnabled = false
                        self.clipboardSyncTimer?.invalidate()
                        self.clipboardSyncTimer = nil
                        self.refreshMenu()
                    }
                    self.showTransientIcon(.error, tooltip: "Android action failed")
                    self.showNonFatalError("Could not send to Android: \(error.localizedDescription)")
                }
            }
        }
    }

    private func phoneMenuTitle() -> String {
        guard let state = currentPhoneState?.state.lowercased() else {
            return "Phone: waiting for Android permission"
        }
        switch state {
        case "ringing":
            return "Phone: incoming \(currentPhoneState?.displayName ?? "Android call")"
        case "active":
            return "Phone: active Android call"
        default:
            return "Phone: ready"
        }
    }

    @objc private func callNumberOnAndroid() {
        guard let number = promptForPhoneNumber() else { return }
        guard let normalized = normalizedDialNumber(number) else {
            showNonFatalError("Enter a normal phone number with digits and an optional leading +.")
            return
        }
        sendActionToAndroid(type: "phone_call", text: normalized, successTooltip: "Android call started")
    }

    @objc private func answerAndroidCall() {
        sendActionToAndroid(type: "phone_answer", text: "answer", successTooltip: "Answered Android call")
    }

    @objc private func declineAndroidCall() {
        sendActionToAndroid(type: "phone_decline", text: "decline", successTooltip: "Declined Android call")
    }

    @objc private func hangupAndroidCall() {
        sendActionToAndroid(type: "phone_hangup", text: "hangup", successTooltip: "Ended Android call")
    }

    private func promptForPhoneNumber() -> String? {
        let alert = NSAlert()
        alert.messageText = "Call on Android"
        alert.informativeText = "The call starts on your phone. Audio stays on Android."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Call")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "+911234567890"
        alert.accessoryView = input
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    private func normalizedDialNumber(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
        var output = ""
        var digits = 0
        for (index, scalar) in trimmed.unicodeScalars.enumerated() {
            if CharacterSet.decimalDigits.contains(scalar) {
                output.unicodeScalars.append(scalar)
                digits += 1
            } else if scalar == "+", index == 0 {
                output.append("+")
            } else if [" ", ".", "(", ")", "-"].contains(String(scalar)) {
                continue
            } else {
                return nil
            }
        }
        guard digits >= 2, digits <= 15 else { return nil }
        return output
    }

    @objc private func openTransferLog() {
        guard let app else { return }
        NSWorkspace.shared.open(app.logFile)
    }

    @objc private func checkForUpdates() {
        guard let appUpdater else {
            showNonFatalError("Updater is not configured. Set LinkitUpdateManifestURL in the app bundle or LINKIT_UPDATE_MANIFEST_URL.")
            return
        }

        showTransientIcon(.pairing, tooltip: "Checking for updates")
        Task {
            do {
                let result = try await appUpdater.checkForUpdates()
                await MainActor.run {
                    switch result {
                    case .upToDate:
                        self.showTransientIcon(.success, tooltip: "Linkit is up to date")
                        self.showUpdateAlert(
                            title: "Linkit is up to date",
                            message: "You are running \(appUpdater.currentVersion) (\(appUpdater.currentBuild))."
                        )
                    case let .available(update):
                        self.confirmAndInstall(update, appUpdater: appUpdater)
                    }
                }
            } catch {
                await MainActor.run {
                    self.showTransientIcon(.error, tooltip: "Update check failed")
                    self.showNonFatalError("Could not check for updates: \(error.localizedDescription)")
                }
            }
        }
    }

    private func confirmAndInstall(_ update: LinkitAvailableUpdate, appUpdater: MacAppUpdater) {
        let notes = update.manifest.releaseNotes.flatMap { $0.isEmpty ? nil : $0 }
        let message = [
            "Version \(update.version) (\(update.build)) is available.",
            notes
        ].compactMap { $0 }.joined(separator: "\n\n")

        let alert = NSAlert()
        alert.messageText = "Update Linkit?"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else {
            refreshStatusButton()
            return
        }

        showTransientIcon(.transferring(direction: .androidToMac), tooltip: "Installing update")
        Task {
            do {
                try await appUpdater.install(update)
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.showTransientIcon(.error, tooltip: "Update failed")
                    self.showNonFatalError("Could not install update: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func showDiagnostics() {
        guard let app else { return }

        let trustedCount = app.trustedDevices().count
        let recent = app.recentTransfers(limit: 5)
        let body = [
            "Status: receiving",
            "IP: \(LocalNetwork.bestPrivateIPv4())",
            "Port: \(app.configuration.port)",
            "Drop: \(app.dropFolder.path)",
            "Trusted devices: \(trustedCount)",
            "Recent transfers: \(recent.count)",
            "Log: \(app.logFile.path)"
        ].joined(separator: "\n")

        let text = NSTextField(wrappingLabelWithString: body)
        text.frame = NSRect(x: 24, y: 24, width: 420, height: 180)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isSelectable = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 468, height: 228))
        content.addSubview(text)

        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Linkit Diagnostics"
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        diagnosticsWindow = window
    }

    @objc private func showPreferences() {
        if let preferencesWindow {
            preferencesWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 188))

        let title = label("Preferences", frame: NSRect(x: 24, y: 138, width: 360, height: 26), size: 20, weight: .semibold)
        let launchCheckbox = NSButton(checkboxWithTitle: "Launch Linkit at login", target: self, action: #selector(setLaunchAtLogin(_:)))
        launchCheckbox.frame = NSRect(x: 24, y: 100, width: 280, height: 24)
        launchCheckbox.state = isLaunchAtLoginEnabled ? .on : .off
        launchCheckbox.isEnabled = isRunningFromAppBundle

        let explanation = isRunningFromAppBundle
            ? "Starts the menu-bar receiver automatically after you sign in."
            : "Build and run dist/Linkit.app to enable this setting."
        let helper = NSTextField(wrappingLabelWithString: explanation)
        helper.frame = NSRect(x: 24, y: 62, width: 392, height: 34)
        helper.textColor = NSColor.secondaryLabelColor
        helper.font = .systemFont(ofSize: 12)

        let keyStorage = NSTextField(wrappingLabelWithString: "Mac identity key: Keychain")
        keyStorage.frame = NSRect(x: 24, y: 28, width: 392, height: 20)
        keyStorage.textColor = NSColor.secondaryLabelColor
        keyStorage.font = .systemFont(ofSize: 12, weight: .medium)

        content.addSubview(title)
        content.addSubview(launchCheckbox)
        content.addSubview(helper)
        content.addSubview(keyStorage)

        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Linkit Preferences"
        window.delegate = self
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow = window
    }

    @objc private func openRecentTransfer(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func refreshMenuAction() {
        checkForTrustChanges()
        refreshMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        setLaunchAtLogin(enabled: !isLaunchAtLoginEnabled)
    }

    @objc private func setLaunchAtLogin(_ sender: NSButton) {
        setLaunchAtLogin(enabled: sender.state == .on)
        sender.state = isLaunchAtLoginEnabled ? .on : .off
    }

    private func setLaunchAtLogin(enabled: Bool) {
        guard isRunningFromAppBundle else {
            showNonFatalError("Launch at login is only available from the packaged Linkit.app.")
            refreshMenu()
            return
        }
        do {
            if enabled {
                if !isLaunchAtLoginEnabled {
                    try SMAppService.mainApp.register()
                }
            } else if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            }
            refreshMenu()
        } catch {
            showNonFatalError("Could not update launch at login: \(error.localizedDescription)")
            refreshMenu()
        }
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func launchAtLoginMenuTitle() -> String {
        "Launch at Login: \(isLaunchAtLoginEnabled ? "On" : "Off")"
    }

    @objc private func disconnectDevice(_ sender: NSMenuItem) {
        guard let deviceId = sender.representedObject as? String else { return }
        app?.disconnectDevice(deviceId)
        refreshStatusButton()
        refreshMenu()
    }

    @objc private func forgetDevice(_ sender: NSMenuItem) {
        guard let app, let deviceId = sender.representedObject as? String else { return }
        do {
            try app.forgetDevice(deviceId)
            lastTrustedSignature = ""
            lastConnectedSignature = ""
            refreshStatusButton()
            refreshMenu()
        } catch {
            showNonFatalError("Could not forget device: \(error.localizedDescription)")
        }
    }

    @objc private func refreshDeviceStatus(_ sender: NSMenuItem) {
        guard let app, let deviceId = sender.representedObject as? String else { return }
        statusIcon?.setState(.transferring(direction: .macToAndroid), tooltip: "Refreshing device status")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let connected = try app.refreshConnectedDevice(deviceId)
                DispatchQueue.main.async {
                    let battery = connected.batteryPercent.map { "\($0)%" } ?? "unknown"
                    self.showTransientIcon(.success, tooltip: "Battery \(battery)")
                    self.refreshMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    if let failure = error as? HTTPFailure,
                       failure.status == 401 || failure.error == "device_status_mismatch" {
                        app.disconnectDevice(deviceId)
                    }
                    self.showTransientIcon(.error, tooltip: "Device status unavailable")
                    self.refreshMenu()
                    self.showNonFatalError("Could not refresh device status: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func quit() {
        transferObservers.forEach(NotificationCenter.default.removeObserver)
        transferObservers.removeAll()
        if let deviceObserver {
            NotificationCenter.default.removeObserver(deviceObserver)
        }
        deviceObserver = nil
        presenceTimer?.invalidate()
        presenceTimer = nil
        networkRefreshWorkItem?.cancel()
        networkRefreshWorkItem = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkForTrustChanges()
        refreshMenu()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        if closedWindow === qrWindow {
            qrWindow = nil
            refreshStatusButton()
        } else if closedWindow === preferencesWindow {
            preferencesWindow = nil
        } else if closedWindow === diagnosticsWindow {
            diagnosticsWindow = nil
        }
    }

    private func installDropTarget(on button: NSStatusBarButton?) {
        guard let button else { return }
        let dropView = StatusDropView(frame: button.bounds)
        dropView.autoresizingMask = [.width, .height]
        dropView.button = button
        dropView.onDrop = { [weak self] urls in
            self?.sendDroppedFiles(urls)
        }
        button.addSubview(dropView)
    }

    private func sendDroppedFiles(_ urls: [URL]) {
        guard let app else { return }
        let fileSizes = urls.map { url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
        let totalBytes = fileSizes.reduce(0, +)
        let startedAt = Date()
        let cancellation = LinkitCancellationToken()
        activeOutgoingCancellation = cancellation
        showTransferPanel(
            state: LinkitTransferPanelState(
                title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files",
                detail: "Sending to Android",
                progress: nil,
                bytesDone: 0,
                totalBytes: totalBytes,
                speedBytesPerSecond: 0,
                etaSeconds: nil,
                direction: .macToAndroid,
                isActive: true,
                didFail: false
            )
        )
        statusIcon?.setState(.transferring(direction: .macToAndroid), tooltip: "Sending to Android")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let results = try app.sendFilesToFirstAndroid(urls, cancellation: cancellation) { progress in
                    let completedBeforeFile = fileSizes.prefix(progress.fileIndex).reduce(0, +)
                    let done = min(totalBytes, completedBeforeFile + progress.fileBytesSent)
                    let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
                    let speed = Double(done) / elapsed
                    let eta = speed > 1 && totalBytes > done ? Double(totalBytes - done) / speed : nil
                    DispatchQueue.main.async {
                        self.showTransferPanel(
                            state: LinkitTransferPanelState(
                                title: progress.fileCount == 1 ? progress.fileURL.lastPathComponent : "Sending \(progress.fileIndex + 1)/\(progress.fileCount)",
                                detail: "Sending to Android",
                                progress: totalBytes > 0 ? min(1, Double(done) / Double(totalBytes)) : nil,
                                bytesDone: done,
                                totalBytes: totalBytes,
                                speedBytesPerSecond: speed,
                                etaSeconds: eta,
                                direction: .macToAndroid,
                                isActive: true,
                                didFail: false
                            )
                        )
                    }
                }
                DispatchQueue.main.async {
                    if self.activeOutgoingCancellation === cancellation {
                        self.activeOutgoingCancellation = nil
                    }
                    self.showTransferPanel(
                        state: LinkitTransferPanelState(
                            title: results.count == 1 ? results[0].fileURL.lastPathComponent : "\(results.count) files",
                            detail: "Sent to Android",
                            progress: 1,
                            bytesDone: totalBytes,
                            totalBytes: totalBytes,
                            speedBytesPerSecond: totalBytes > 0 ? Double(totalBytes) / max(0.001, Date().timeIntervalSince(startedAt)) : 0,
                            etaSeconds: 0,
                            direction: .macToAndroid,
                            isActive: false,
                            didFail: false
                        )
                    )
                    self.showTransientIcon(.success, tooltip: "Sent \(results.count) file\(results.count == 1 ? "" : "s")")
                    self.refreshMenu()
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    if self.activeOutgoingCancellation === cancellation {
                        self.activeOutgoingCancellation = nil
                    }
                    self.showTransferPanel(
                        state: LinkitTransferPanelState(
                            title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files",
                            detail: "Canceled",
                            progress: 0,
                            bytesDone: 0,
                            totalBytes: totalBytes,
                            speedBytesPerSecond: 0,
                            etaSeconds: nil,
                            direction: .macToAndroid,
                            isActive: false,
                            didFail: true
                        )
                    )
                    self.refreshStatusButton()
                    self.refreshMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    if self.activeOutgoingCancellation === cancellation {
                        self.activeOutgoingCancellation = nil
                    }
                    self.showTransferPanel(
                        state: LinkitTransferPanelState(
                            title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files",
                            detail: "Send failed",
                            progress: 0,
                            bytesDone: 0,
                            totalBytes: totalBytes,
                            speedBytesPerSecond: 0,
                            etaSeconds: nil,
                            direction: .macToAndroid,
                            isActive: false,
                            didFail: true
                        )
                    )
                    self.showTransientIcon(.error, tooltip: "Send failed")
                    self.showNonFatalError("Could not send to Android: \(error.localizedDescription)")
                    self.refreshMenu()
                }
            }
        }
    }

    private func showTransientIcon(_ state: LinkitStatusIconState, tooltip: String) {
        resetStatusWorkItem?.cancel()
        statusIcon?.setState(state, tooltip: tooltip)
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshStatusButton()
        }
        resetStatusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func startTransferObservers() {
        transferObservers.append(
            NotificationCenter.default.addObserver(
                forName: .linkitTransferDidBeginUpload,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let filename = notification.userInfo?[LinkitTransferNotification.filenameKey] as? String
                let size = notification.userInfo?[LinkitTransferNotification.sizeKey] as? Int64
                if let transferId = notification.userInfo?[LinkitTransferNotification.transferIdKey] as? String {
                    self?.transferStartedAtById[transferId] = Date()
                    self?.activeIncomingTransferId = transferId
                }
                let suffix = filename.map { ": \($0)" } ?? ""
                self?.showTransferPanel(
                    state: LinkitTransferPanelState(
                        title: filename ?? "Incoming file",
                        detail: "Receiving from Android",
                        progress: 0,
                        bytesDone: 0,
                        totalBytes: size ?? 0,
                        speedBytesPerSecond: 0,
                        etaSeconds: nil,
                        direction: .androidToMac,
                        isActive: true,
                        didFail: false
                    )
                )
                self?.statusIcon?.setState(.transferring(direction: .androidToMac), tooltip: "Receiving from Android\(suffix)")
            }
        )

        transferObservers.append(
            NotificationCenter.default.addObserver(
                forName: .linkitTransferDidProgress,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self else { return }
                let filename = notification.userInfo?[LinkitTransferNotification.filenameKey] as? String
                let received = notification.userInfo?[LinkitTransferNotification.bytesReceivedKey] as? Int64 ?? 0
                let size = notification.userInfo?[LinkitTransferNotification.sizeKey] as? Int64 ?? 0
                let transferId = notification.userInfo?[LinkitTransferNotification.transferIdKey] as? String
                let startedAt = transferId.flatMap { self.transferStartedAtById[$0] } ?? Date()
                let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
                let speed = Double(received) / elapsed
                let eta = speed > 1 && size > received ? Double(size - received) / speed : nil
                let progress = size > 0 ? min(1, Double(received) / Double(size)) : nil
                self.showTransferPanel(
                    state: LinkitTransferPanelState(
                        title: filename ?? "Incoming file",
                        detail: "Receiving from Android",
                        progress: progress,
                        bytesDone: received,
                        totalBytes: size,
                        speedBytesPerSecond: speed,
                        etaSeconds: eta,
                        direction: .androidToMac,
                        isActive: true,
                        didFail: false
                    )
                )
            }
        )

        transferObservers.append(
            NotificationCenter.default.addObserver(
                forName: .linkitTransferDidFinish,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let status = notification.userInfo?[LinkitTransferNotification.statusKey] as? String
                let filename = notification.userInfo?[LinkitTransferNotification.filenameKey] as? String
                let size = notification.userInfo?[LinkitTransferNotification.sizeKey] as? Int64
                let transferId = notification.userInfo?[LinkitTransferNotification.transferIdKey] as? String
                let startedAt = transferId.flatMap { self?.transferStartedAtById[$0] } ?? Date()
                let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
                let speed = Double(size ?? 0) / elapsed
                if let transferId {
                    self?.transferStartedAtById.removeValue(forKey: transferId)
                    if self?.activeIncomingTransferId == transferId {
                        self?.activeIncomingTransferId = nil
                    }
                }
                if status == "complete" {
                    self?.showTransferPanel(
                        state: LinkitTransferPanelState(
                            title: filename ?? "Transfer complete",
                            detail: "Received from Android",
                            progress: 1,
                            bytesDone: size ?? 0,
                            totalBytes: size ?? 0,
                            speedBytesPerSecond: speed,
                            etaSeconds: 0,
                            direction: .androidToMac,
                            isActive: false,
                            didFail: false
                        )
                    )
                    self?.showTransientIcon(.success, tooltip: "Transfer complete")
                    self?.postReceivedNotification(userInfo: notification.userInfo)
                } else if status == "canceled" {
                    self?.showTransferPanel(
                        state: LinkitTransferPanelState(
                            title: filename ?? "Transfer canceled",
                            detail: "Canceled",
                            progress: 0,
                            bytesDone: 0,
                            totalBytes: size ?? 0,
                            speedBytesPerSecond: 0,
                            etaSeconds: nil,
                            direction: .androidToMac,
                            isActive: false,
                            didFail: true
                        )
                    )
                    self?.refreshStatusButton()
                } else {
                    self?.showTransferPanel(
                        state: LinkitTransferPanelState(
                            title: filename ?? "Transfer failed",
                            detail: "Receive failed",
                            progress: 0,
                            bytesDone: 0,
                            totalBytes: size ?? 0,
                            speedBytesPerSecond: 0,
                            etaSeconds: nil,
                            direction: .androidToMac,
                            isActive: false,
                            didFail: true
                        )
                    )
                    self?.showTransientIcon(.error, tooltip: "Transfer failed")
                    self?.postReceiveFailedNotification(userInfo: notification.userInfo)
                }
                self?.refreshMenu()
            }
        )
    }

    private func startActionObserver() {
        transferObservers.append(
            NotificationCenter.default.addObserver(
                forName: .linkitActionReceived,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let type = notification.userInfo?[LinkitActionNotification.typeKey] as? String,
                      let text = notification.userInfo?[LinkitActionNotification.textKey] as? String
                else { return }
                self.handleIncomingAction(type: type, text: text)
            }
        )
    }

    private func handleIncomingAction(type: String, text: String) {
        switch type {
        case "clipboard", "text":
            setClipboardText(text)
            lastClipboardText = text
            lastClipboardChangeCount = NSPasteboard.general.changeCount
            showTransientIcon(.success, tooltip: type == "clipboard" ? "Clipboard received" : "Text received")
        case "open_url":
            guard let url = validatedWebURL(text) else { return }
            NSWorkspace.shared.open(url)
            showTransientIcon(.success, tooltip: "Opened link")
        case "phone_state":
            handleAndroidPhoneState(text)
        default:
            break
        }
    }

    private func handleAndroidPhoneState(_ text: String) {
        guard let data = text.data(using: .utf8),
              let state = try? JSONDecoder().decode(AndroidPhoneState.self, from: data)
        else { return }
        let oldState = currentPhoneState?.state.lowercased()
        currentPhoneState = state
        refreshMenu()

        switch state.state.lowercased() {
        case "ringing":
            showTransientIcon(.pairing, tooltip: "Incoming Android call")
            if oldState != "ringing" {
                showIncomingCallPrompt(state)
            }
        case "active":
            showTransientIcon(.connected, tooltip: "Android call active")
        default:
            incomingCallAlertVisible = false
        }
    }

    private func showIncomingCallPrompt(_ state: AndroidPhoneState) {
        guard !incomingCallAlertVisible else { return }
        incomingCallAlertVisible = true
        let alert = NSAlert()
        alert.messageText = "Incoming Android call"
        alert.informativeText = state.displayName
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Answer")
        alert.addButton(withTitle: "Decline")
        alert.addButton(withTitle: "Dismiss")
        let result = alert.runModal()
        incomingCallAlertVisible = false
        switch result {
        case .alertFirstButtonReturn:
            answerAndroidCall()
        case .alertSecondButtonReturn:
            declineAndroidCall()
        default:
            break
        }
    }

    private func startDeviceObserver() {
        deviceObserver = NotificationCenter.default.addObserver(
            forName: .linkitDevicesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForTrustChanges()
        }
    }

    private func startPresenceMonitor() {
        presenceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.runPresenceSweep()
        }
        timer.tolerance = 3.0
        presenceTimer = timer
    }

    private func startNetworkMonitor() {
        networkMonitor?.cancel()
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkChange(path)
            }
        }
        monitor.start(queue: networkMonitorQueue)
    }

    private func handleNetworkChange(_ path: NWPath) {
        let signature = [
            "\(path.status)",
            path.availableInterfaces.map { "\($0.type)" }.sorted().joined(separator: ",")
        ].joined(separator: "|")
        guard signature != lastNetworkPathSignature else { return }
        lastNetworkPathSignature = signature

        fputs("Linkit network changed: \(signature)\n", stderr)
        refreshStatusButton()
        refreshMenu()

        networkRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runPresenceSweep(force: true)
        }
        networkRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: workItem)
    }

    private func runPresenceSweep(force: Bool = false) {
        guard let app else { return }
        let connected = app.connectedDevices()
        if connected.isEmpty {
            presenceFailureCounts.removeAll()
            return
        }
        let connectedIds = Set(connected.map { $0.deviceId })
        presenceFailureCounts = presenceFailureCounts.filter { connectedIds.contains($0.key) }
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let stalenessThreshold: TimeInterval = 30
        for device in connected {
            guard let lastSeen = formatter.date(from: device.lastSeenAt) else { continue }
            guard force || now.timeIntervalSince(lastSeen) >= stalenessThreshold else { continue }
            let deviceId = device.deviceId
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    _ = try app.refreshConnectedDevice(deviceId)
                    DispatchQueue.main.async {
                        self?.presenceFailureCounts[deviceId] = 0
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if force {
                            self.presenceFailureCounts[deviceId] = 0
                            app.disconnectDevice(deviceId)
                            self.refreshStatusButton()
                            self.refreshMenu()
                            return
                        }
                        let next = (self.presenceFailureCounts[deviceId] ?? 0) + 1
                        self.presenceFailureCounts[deviceId] = next
                        if next >= self.presenceFailureThreshold {
                            self.presenceFailureCounts[deviceId] = 0
                            app.disconnectDevice(deviceId)
                        }
                    }
                }
            }
        }
    }

    private func configureNotifications() {
        guard isRunningFromAppBundle else {
            fputs("Linkit notifications disabled: run the packaged .app to enable macOS notification banners.\n", stderr)
            return
        }

        let center = UNUserNotificationCenter.current()
        notificationCenter = center
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let reveal = UNNotificationAction(identifier: "linkit.reveal", title: "Show in Finder", options: [])
        let open = UNNotificationAction(identifier: "linkit.open", title: "Open", options: [.foreground])
        let category = UNNotificationCategory(identifier: "linkit.receive", actions: [open, reveal], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func postReceivedNotification(userInfo: [AnyHashable: Any]?) {
        guard let notificationCenter else { return }
        guard let filename = userInfo?[LinkitTransferNotification.filenameKey] as? String else { return }
        let senderId = userInfo?[LinkitTransferNotification.senderDeviceIdKey] as? String
        let savedPath = (userInfo?[LinkitTransferNotification.savedPathKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let size = userInfo?[LinkitTransferNotification.sizeKey] as? Int64
        let senderName = trustedDeviceName(forId: senderId) ?? "your device"

        let content = UNMutableNotificationContent()
        content.title = "Received from \(senderName)"
        var subtitle = filename
        if let size, size > 0 {
            subtitle += " · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
        }
        content.body = subtitle
        content.sound = .default
        content.categoryIdentifier = "linkit.receive"
        if let savedPath { content.userInfo = ["savedPath": savedPath] }

        let request = UNNotificationRequest(identifier: "linkit.received.\(UUID().uuidString)", content: content, trigger: nil)
        notificationCenter.add(request, withCompletionHandler: nil)
    }

    private func postReceiveFailedNotification(userInfo: [AnyHashable: Any]?) {
        guard let notificationCenter else { return }
        guard let filename = userInfo?[LinkitTransferNotification.filenameKey] as? String else { return }
        let error = (userInfo?[LinkitTransferNotification.errorKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let content = UNMutableNotificationContent()
        content.title = "Linkit transfer failed"
        content.body = error.map { "\(filename) — \($0)" } ?? filename
        content.sound = .default
        let request = UNNotificationRequest(identifier: "linkit.failed.\(UUID().uuidString)", content: content, trigger: nil)
        notificationCenter.add(request, withCompletionHandler: nil)
    }

    private func trustedDeviceName(forId deviceId: String?) -> String? {
        guard let deviceId, !deviceId.isEmpty, let app else { return nil }
        return app.trustedDevices().first { $0.deviceId == deviceId }?.deviceName
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let savedPath = response.notification.request.content.userInfo["savedPath"] as? String
        switch response.actionIdentifier {
        case "linkit.reveal":
            if let savedPath {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: savedPath)])
            } else if let dropFolder = app?.dropFolder {
                NSWorkspace.shared.open(dropFolder)
            }
        case "linkit.open", UNNotificationDefaultActionIdentifier:
            if let savedPath {
                NSWorkspace.shared.open(URL(fileURLWithPath: savedPath))
            } else if let dropFolder = app?.dropFolder {
                NSWorkspace.shared.open(dropFolder)
            }
        default:
            break
        }
        completionHandler()
    }

    private func showTransferPanel(state: LinkitTransferPanelState) {
        currentTransfer = state
        let panel = transferPanel ?? LinkitTransferPanel()
        transferPanel = panel
        panel.onCancel = { [weak self] in self?.cancelCurrentTransfer() }
        panel.update(state: state)
        if let button = statusItem?.button {
            panel.show(relativeTo: button)
        } else {
            panel.showCentered()
        }
        if !state.isActive {
            panel.closeAfterDelay(5)
        }
    }

    private func cancelCurrentTransfer() {
        if currentTransfer?.direction == .macToAndroid {
            activeOutgoingCancellation?.cancel()
            return
        }
        guard let transferId = activeIncomingTransferId else { return }
        do {
            try app?.cancelIncomingTransfer(transferId)
        } catch {
            showNonFatalError("Could not cancel transfer: \(error.localizedDescription)")
        }
    }

    private func idleTransferState() -> LinkitTransferPanelState {
        LinkitTransferPanelState(
            title: "No active transfer",
            detail: "Recent Linkit drops",
            progress: nil,
            bytesDone: 0,
            totalBytes: 0,
            speedBytesPerSecond: 0,
            etaSeconds: nil,
            direction: .androidToMac,
            isActive: false,
            didFail: false
        )
    }

    private func recentTransfersMenuItem(app: LinkitReceiverApp) -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Transfers", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let entries = app.recentTransfers(limit: 8)
        if entries.isEmpty {
            submenu.addItem(NSMenuItem(title: "No transfers yet", action: nil, keyEquivalent: ""))
        } else {
            for entry in entries {
                let title = "\(entry.filename)  \(entry.status)"
                let recentItem = NSMenuItem(title: title, action: entry.savedPath == nil ? nil : #selector(openRecentTransfer(_:)), keyEquivalent: "")
                recentItem.representedObject = entry.savedPath
                submenu.addItem(recentItem)
            }
        }
        item.submenu = submenu
        return item
    }

    private func batterySuffix(_ percent: Int?) -> String {
        guard let percent else { return "" }
        return " - \(percent)% battery"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func currentClipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setClipboardText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func validatedWebURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    private func label(_ text: String, frame: NSRect, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func qrImage(from text: String, size: CGFloat) -> NSImage? {
        guard
            let data = text.data(using: .utf8),
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale = size / output.extent.width
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Linkit"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func showNonFatalError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Linkit"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

private final class LinkitTransferPanel {
    private let popover: NSPopover
    private let content: LinkitTransferPanelView
    private var closeWorkItem: DispatchWorkItem?
    var onCancel: (() -> Void)? {
        get { content.onCancel }
        set { content.onCancel = newValue }
    }

    init() {
        content = LinkitTransferPanelView(frame: NSRect(origin: .zero, size: NSSize(width: 340, height: 150)))
        let controller = NSViewController()
        controller.view = content

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = controller
    }

    func update(state: LinkitTransferPanelState) {
        closeWorkItem?.cancel()
        content.transferState = state
        popover.contentSize = content.preferredSize(maxWidth: NSScreen.main?.visibleFrame.width ?? 380)
    }

    func show(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.contentSize = content.preferredSize(maxWidth: button.window?.screen?.visibleFrame.width ?? 380)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func showCentered() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeAfterDelay(_ delay: TimeInterval) {
        closeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.popover.performClose(nil)
        }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

private final class LinkitTransferPanelView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "Linkit")
    private let cardView = NSView()
    private let iconView = NSImageView()
    private let transferTitle = NSTextField(labelWithString: "")
    private let transferDetail = NSTextField(labelWithString: "")
    private let transferStats = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: (() -> Void)?

    var transferState: LinkitTransferPanelState = LinkitTransferPanelState(
        title: "No active transfer",
        detail: "Ready",
        progress: nil,
        bytesDone: 0,
        totalBytes: 0,
        speedBytesPerSecond: 0,
        etaSeconds: nil,
        direction: .androidToMac,
        isActive: false,
        didFail: false
    ) {
        didSet { updateContent() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let width = min(340, max(280, maxWidth - 48))
        return NSSize(width: width, height: 150)
    }

    private func setup() {
        material = .popover
        blendingMode = .behindWindow
        self.state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.textColor = .labelColor

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 14
        cardView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.36).cgColor
        cardView.layer?.borderWidth = 1

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        iconView.contentTintColor = .white
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 20
        iconView.layer?.masksToBounds = true

        transferTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        transferTitle.lineBreakMode = .byTruncatingMiddle
        transferTitle.maximumNumberOfLines = 1

        transferDetail.font = .systemFont(ofSize: 11, weight: .medium)
        transferDetail.textColor = .secondaryLabelColor

        transferStats.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        transferStats.textColor = .secondaryLabelColor
        transferStats.lineBreakMode = .byTruncatingTail

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        percentLabel.alignment = .right
        percentLabel.textColor = .secondaryLabelColor

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.style = .bar

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 11, weight: .medium)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        [titleLabel, cardView].forEach(addSubview)
        [iconView, transferTitle, transferDetail, transferStats, percentLabel, progressBar, cancelButton].forEach(cardView.addSubview)
        updateContent()
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 14
        titleLabel.frame = NSRect(x: padding, y: bounds.height - 32, width: bounds.width - padding * 2, height: 20)

        let cardHeight: CGFloat = 96
        cardView.frame = NSRect(x: padding, y: 14, width: bounds.width - padding * 2, height: cardHeight)
        iconView.frame = NSRect(x: 15, y: cardHeight - 58, width: 40, height: 40)
        percentLabel.frame = NSRect(x: cardView.bounds.width - 55, y: cardHeight - 38, width: 38, height: 14)
        transferTitle.frame = NSRect(x: 66, y: cardHeight - 36, width: cardView.bounds.width - 130, height: 17)
        transferDetail.frame = NSRect(x: 66, y: cardHeight - 55, width: cardView.bounds.width - 82, height: 14)
        transferStats.frame = NSRect(x: 66, y: cardHeight - 73, width: cardView.bounds.width - 142, height: 13)
        cancelButton.frame = NSRect(x: cardView.bounds.width - 66, y: 28, width: 50, height: 24)
        progressBar.frame = NSRect(x: 66, y: 13, width: cardView.bounds.width - 82, height: 5)
    }

    private func updateContent() {
        cardView.layer?.borderColor = accentColor.withAlphaComponent(transferState.isActive ? 0.9 : 0.45).cgColor
        iconView.layer?.backgroundColor = accentColor.cgColor
        iconView.image = NSImage(systemSymbolName: transferState.direction == .androidToMac ? "arrow.down" : "arrow.up", accessibilityDescription: nil)
        transferTitle.stringValue = transferState.title
        transferDetail.stringValue = transferState.detail
        transferStats.stringValue = transferStatsText()
        percentLabel.stringValue = transferState.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
        cancelButton.isHidden = !transferState.isActive
        if let progress = transferState.progress {
            progressBar.isIndeterminate = false
            progressBar.doubleValue = progress
        } else {
            progressBar.isIndeterminate = transferState.isActive
            progressBar.startAnimation(nil)
        }
        needsLayout = true
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    private func transferStatsText() -> String {
        guard transferState.totalBytes > 0 else {
            return transferState.isActive ? "Preparing..." : "Idle"
        }
        let bytes = "\(formatBytes(transferState.bytesDone)) / \(formatBytes(transferState.totalBytes))"
        let speed = transferState.speedBytesPerSecond > 1 ? "\(formatBytes(Int64(transferState.speedBytesPerSecond)))/s" : "--/s"
        let eta = transferState.etaSeconds.map(formatDuration) ?? "--"
        return "\(bytes)  \(speed)  \(eta)"
    }

    private var accentColor: NSColor {
        if transferState.didFail { return .systemRed }
        return transferState.direction == .androidToMac ? .systemPurple : .systemBlue
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    if seconds <= 1 { return "now" }
    let rounded = Int(seconds.rounded())
    if rounded < 60 { return "\(rounded)s left" }
    return "\(rounded / 60)m \(rounded % 60)s left"
}

final class StatusDropView: NSView {
    weak var button: NSStatusBarButton?
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func mouseDown(with event: NSEvent) {
        button?.performClick(nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { object in
            if let url = object as? URL { return url }
            return (object as? NSURL)?.absoluteURL
        }
    }
}

let application = NSApplication.shared
let delegate = LinkitMenuDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
