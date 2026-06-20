import AppKit
import Combine
import CoreImage
import LinkitMacCore
import Network
import ServiceManagement
import SwiftUI
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
    let name: String?
    let timestampMillis: Int64?
    let canAnswer: Bool?
    let canEnd: Bool?

    var displayName: String {
        let hasName = name?.isEmpty == false
        let hasNumber = number?.isEmpty == false
        if hasName && hasNumber {
            return "\(name!) (\(number!))"
        }
        if hasName {
            return name!
        }
        if hasNumber {
            return number!
        }
        return "Android call"
    }

    var callPanelTitle: String {
        if let name, !name.isEmpty { return name }
        if let number, !number.isEmpty { return number }
        return "Android call"
    }

    var callPanelSubtitle: String {
        let hasName = name?.isEmpty == false
        let hasNumber = number?.isEmpty == false
        if hasName && hasNumber { return number! }
        return "Android call"
    }
}

private enum LinkitCallPanelMode {
    case ringing
    case active
}

final class LinkitMenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var app: LinkitReceiverApp?
    private var statusItem: NSStatusItem?
    private var statusIcon: StatusIconAnimator?
    private let panelViewModel = PanelViewModel()
    private let settingsViewModel = SettingsViewModel()
    private let callPickerViewModel = CallPickerViewModel()
    private var callPickerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var popover: NSPopover?
    private var popoverClosedAt = Date.distantPast
    private var transferStripClearWorkItem: DispatchWorkItem?
    private var qrWindow: NSWindow?
    private var retiredWindows: [NSWindow] = []
    private var transferPanel: LinkitTransferPanel?
    private var currentTransfer: LinkitTransferPanelState?
    private var transferStartedAtById: [String: Date] = [:]
    private var activeOutgoingCancellation: LinkitCancellationToken?
    private var activeIncomingTransferId: String?
    private var resetStatusWorkItem: DispatchWorkItem?
    private var transferObservers: [NSObjectProtocol] = []
    private var deviceObserver: NSObjectProtocol?
    private var clipboardSyncTimer: Timer?
    private let prefs = Preferences.shared
    /// Proxies the persisted preference so existing call sites keep working and
    /// the choice survives relaunch.
    private var clipboardSyncEnabled: Bool {
        get { prefs.clipboardSyncEnabled }
        set { prefs.clipboardSyncEnabled = newValue }
    }
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
    private var callPanel: LinkitCallPanel?
    private var callDismissedByUser = false
    private var callAnsweredFromMac = false
    private var callAudioSetupTimer: Timer?
    private let handsFreeBridge = HandsFreeBridge.shared
    private var notificationCenter: UNUserNotificationCenter?
    private var appUpdater: MacAppUpdater?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeAppearance()
        configureNotifications()
        appUpdater = try? MacAppUpdater()
        do {
            let receiver = try LinkitReceiverApp(
                configuration: makeReceiverConfiguration(),
                bluetoothAddressProvider: { BluetoothInfo.macAddress() }
            )
            self.app = receiver
            setupHandsFreeBridge()
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

    private func setupHandsFreeBridge() {
        handsFreeBridge.onStateChange = { [weak self] in
            self?.refreshPanel()
        }
        handsFreeBridge.connectIfNeeded()
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: 38)
        installDropTarget(on: item.button)
        statusItem = item
        if let button = item.button {
            statusIcon = StatusIconAnimator(button: button)
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        wirePanelActions()
        wireSettingsActions()
        refreshStatusButton()
        refreshPanel()
        startTransferObservers()
        startActionObserver()
        startDeviceObserver()
        startPresenceMonitor()
        startNetworkMonitor()
        if clipboardSyncEnabled {
            startClipboardSync()
        }
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
            refreshPanel()

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

    /// Pushes the current core state into the SwiftUI popover view model. Named
    /// `refreshPanel` (formerly `refreshMenu`) and still called from every place
    /// that used to rebuild the flat menu.
    private func refreshPanel() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshPanel() }
            return
        }
        guard let app else { return }
        let trusted = app.trustedDevices()
        let connected = app.connectedDevices()
        let androidTargets = connected.filter { $0.platform.lowercased() == "android" }
        let pairedAndroid = trusted.first { $0.platform.lowercased() == "android" } ?? trusted.first

        panelViewModel.localAddress = "\(LocalNetwork.bestPrivateIPv4()):\(app.configuration.port)"
        panelViewModel.pairedDeviceName = pairedAndroid?.deviceName
        panelViewModel.connectedDeviceName = androidTargets.first?.deviceName
        panelViewModel.batteryPercent = androidTargets.first?.batteryPercent
        panelViewModel.isConnected = !androidTargets.isEmpty
        panelViewModel.hasAndroidTarget = !androidTargets.isEmpty
        panelViewModel.clipboardSyncEnabled = clipboardSyncEnabled
        panelViewModel.phone = panelPhoneState()
        panelViewModel.callAudioStatus = handsFreeBridge.statusLabel
        panelViewModel.callAudioConfigured = handsFreeBridge.isConnected
        panelViewModel.callAudioOnMac = handsFreeBridge.audioLocation == .mac
        panelViewModel.recentTransfers = app.recentTransfers(limit: 8).enumerated().map { index, entry in
            RecentTransferRow(
                id: "\(index)-\(entry.filename)",
                filename: entry.filename,
                status: entry.status,
                savedPath: entry.savedPath,
                direction: .unknown
            )
        }
    }

    private func panelPhoneState() -> PanelPhoneState {
        var phone = PanelPhoneState()
        guard let state = currentPhoneState?.state.lowercased() else {
            phone.statusText = "Waiting for Android permission"
            return phone
        }
        switch state {
        case "ringing":
            phone.isRinging = true
            phone.statusText = "Incoming call"
            phone.callerLabel = currentPhoneState?.displayName
        case "active":
            phone.isActive = true
            phone.statusText = "On a call"
            phone.callerLabel = currentPhoneState?.displayName
        default:
            phone.statusText = "Ready"
        }
        return phone
    }

    /// Connects the popover's buttons to the delegate's existing handlers.
    private func wirePanelActions() {
        panelViewModel.onSendFile = { [weak self] in self?.pickFilesToSend() }
        panelViewModel.onSendClipboard = { [weak self] in self?.sendClipboardTextToAndroid() }
        panelViewModel.onOpenLink = { [weak self] in self?.openClipboardLinkOnAndroid() }
        panelViewModel.onToggleClipboardSync = { [weak self] in self?.toggleClipboardSync() }
        panelViewModel.onShowQR = { [weak self] in self?.closePopover(); self?.showPairingQR() }
        panelViewModel.onReconnect = { [weak self] in self?.refreshAllDeviceStatus() }
        panelViewModel.onCallNumber = { [weak self] in self?.callNumberOnAndroid() }
        panelViewModel.onAnswer = { [weak self] in self?.answerAndroidCall() }
        panelViewModel.onDecline = { [weak self] in self?.declineAndroidCall() }
        panelViewModel.onHangUp = { [weak self] in self?.hangupAndroidCall() }
        panelViewModel.onSetupCallAudio = { [weak self] in self?.setupCallAudio() }
        panelViewModel.onToggleCallAudioRoute = { [weak self] in self?.toggleCallAudioRoute() }
        panelViewModel.onOpenDropFolder = { [weak self] in self?.openDropFolder() }
        panelViewModel.onOpenRecent = { [weak self] path in
            self?.openRecentTransferPath(path)
        }
        panelViewModel.onCancelTransfer = { [weak self] in self?.cancelCurrentTransfer() }
        panelViewModel.onOpenSettings = { [weak self] in self?.closePopover(); self?.showSettings() }
        panelViewModel.onQuit = { [weak self] in self?.quit() }
    }

    // MARK: Status item interaction

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showFallbackMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        // The transient popover dismisses on the click that re-opens it; this
        // guard stops the same click from immediately re-showing it.
        if Date().timeIntervalSince(popoverClosedAt) < 0.25 { return }
        refreshPanel()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: LinkitPanelView(model: panelViewModel))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        popover = nil
    }

    /// Minimal right-click safety net so the app is never stuck if the popover
    /// misbehaves.
    private func showFallbackMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Linkit", action: #selector(togglePopoverAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Linkit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func togglePopoverAction() {
        togglePopover()
    }

    /// Lets the user pick files to send to Android (the drag-to-icon path still
    /// works too).
    @objc private func pickFilesToSend() {
        closePopover()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to your Android device"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        sendDroppedFiles(panel.urls)
    }

    private func openRecentTransferPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func refreshAllDeviceStatus() {
        guard let app else { return }
        for device in app.connectedDevices() {
            _ = try? app.refreshConnectedDevice(device.deviceId)
        }
        refreshStatusButton()
        refreshPanel()
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
            startClipboardSync()
            showTransientIcon(.success, tooltip: "Clipboard sync on")
        } else {
            stopClipboardSync()
            showTransientIcon(.connected, tooltip: "Clipboard sync off")
        }
        refreshPanel()
    }

    private func startClipboardSync() {
        lastClipboardChangeCount = NSPasteboard.general.changeCount
        lastClipboardText = currentClipboardText()
        clipboardSyncTimer?.invalidate()
        clipboardSyncTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollClipboardForSync()
        }
    }

    private func stopClipboardSync() {
        clipboardSyncTimer?.invalidate()
        clipboardSyncTimer = nil
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
                        self.stopClipboardSync()
                        self.refreshPanel()
                    }
                    self.showTransientIcon(.error, tooltip: "Android action failed")
                    self.showNonFatalError("Could not send to Android: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func callNumberOnAndroid() {
        showCallPicker()
    }

    /// Normalizes a picked/typed number and places the call, preferring Mac-routed Hands-Free
    /// audio when connected and otherwise asking Android to dial.
    private func dialNormalizedNumber(_ raw: String) {
        guard let normalized = normalizedDialNumber(raw) else {
            showNonFatalError("Enter a normal phone number with digits and an optional leading +.")
            return
        }
        if handsFreeBridge.dial(normalized) {
            showTransientIcon(.success, tooltip: "Calling from Mac audio")
            return
        }
        sendActionToAndroid(type: "phone_call", text: normalized, successTooltip: "Android call started")
    }

    private func showCallPicker() {
        closePopover()
        callPickerViewModel.loadPhonebook = { [weak self] in
            guard let app = self?.app else {
                throw NSError(
                    domain: "Linkit",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Connect your Android first by opening Linkit."]
                )
            }
            return try app.fetchPhonebookFromFirstAndroid()
        }
        callPickerViewModel.onDial = { [weak self] number in
            self?.dialNormalizedNumber(number)
        }
        callPickerViewModel.onClose = { [weak self] in
            self?.callPickerWindow?.close()
        }
        if let callPickerWindow {
            callPickerViewModel.query = ""
            callPickerViewModel.reload()
            callPickerWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: CallPickerView(model: callPickerViewModel))
        let window = NSWindow(contentViewController: host)
        window.title = "Call on Android"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 380, height: 480))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        callPickerWindow = window
    }

    @objc private func answerAndroidCall() {
        answerCallOnPhone()
    }

    @objc private func declineAndroidCall() {
        if handsFreeBridge.isConnected {
            handsFreeBridge.hangUp()
        }
        sendActionToAndroid(type: "phone_decline", text: "decline", successTooltip: "Declined Android call")
    }

    @objc private func hangupAndroidCall() {
        hangUpCurrentCall()
    }

    @objc private func setupCallAudio() {
        guard let macAddress = BluetoothInfo.macAddress() else {
            showNonFatalError("Bluetooth is not available on this Mac.")
            return
        }
        guard let app else { return }
        let knownBefore = Set(BluetoothInfo.pairedDeviceAddresses())
        let payload = "{\"address\":\"\(macAddress)\"}"
        showTransientIcon(.pairing, tooltip: "Setting up call audio")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try app.sendActionToFirstAndroid(LinkitActionRequest(type: "bt_pair", text: payload))
                DispatchQueue.main.async {
                    self.handleCallAudioSetupResponse(response, knownBefore: knownBefore)
                }
            } catch {
                DispatchQueue.main.async {
                    self.showTransientIcon(.error, tooltip: "Call audio setup failed")
                    self.showRetryableError(
                        "Could not reach Android for call audio setup: \(error.localizedDescription)",
                        retry: { self.setupCallAudio() }
                    )
                }
            }
        }
    }

    private func showRetryableError(_ message: String, retry: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Linkit"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            retry()
        }
    }

    private func handleCallAudioSetupResponse(_ response: LinkitActionResponse, knownBefore: Set<String>) {
        let phoneName = response.bluetoothName?.lowercased()
        // The Android side told us its Bluetooth name; find that exact device.
        if let phoneName, !phoneName.isEmpty,
           let address = BluetoothInfo.pairedDeviceAddress(named: [phoneName]) {
            adoptPhoneForCallAudio(address)
            return
        }
        if response.mode == "already_paired", let address = detectPairedPhoneAddress() {
            adoptPhoneForCallAudio(address)
            return
        }
        showTransientIcon(.pairing, tooltip: "Confirm pairing on your phone")
        startCallAudioSetupPolling(knownBefore: knownBefore, phoneName: phoneName)
    }

    private func adoptPhoneForCallAudio(_ address: String) {
        handsFreeBridge.setPhoneAddress(address)
        showTransientIcon(.success, tooltip: "Call audio ready on Mac")
        refreshPanel()
    }

    private func detectPairedPhoneAddress() -> String? {
        // Prefer a paired device whose name matches a Linkit-trusted Android device.
        let androidNames = Set(
            (app?.trustedDevices() ?? [])
                .filter { $0.platform.lowercased() == "android" }
                .map { $0.deviceName.lowercased() }
        )
        if let named = BluetoothInfo.pairedDeviceAddress(named: androidNames) {
            return named
        }
        // Fall back to Bluetooth device class: paired phones.
        let phones = BluetoothInfo.pairedPhoneAddresses()
        return phones.count == 1 ? phones.first : nil
    }

    @objc private func toggleCallAudioRoute() {
        if handsFreeBridge.audioLocation == .mac {
            handsFreeBridge.moveAudioToPhone()
            showTransientIcon(.success, tooltip: "Call audio moved to phone")
        } else {
            handsFreeBridge.moveAudioToMac()
            showTransientIcon(.success, tooltip: "Call audio moved to Mac")
        }
        refreshPanel()
        if let state = currentPhoneState, callPanel?.isShown == true {
            callPanel?.present(
                state: state,
                mode: state.state.lowercased() == "ringing" ? .ringing : .active,
                hfpConnected: handsFreeBridge.isConnected,
                audioOnMac: handsFreeBridge.audioLocation == .mac
            )
        }
    }

    private func answerCallOnMac() {
        callAnsweredFromMac = true
        if handsFreeBridge.isConnected {
            handsFreeBridge.answerOnMac()
        } else {
            sendActionToAndroid(type: "phone_answer", text: "answer", successTooltip: "Answered Android call")
        }
        if let state = currentPhoneState {
            callPanel?.present(
                state: state,
                mode: .active,
                hfpConnected: handsFreeBridge.isConnected,
                audioOnMac: true
            )
        }
    }

    private func answerCallOnPhone() {
        if handsFreeBridge.isConnected {
            handsFreeBridge.answerOnPhone()
        } else {
            sendActionToAndroid(type: "phone_answer", text: "answer", successTooltip: "Answered on phone")
        }
        callAnsweredFromMac = true
        if let state = currentPhoneState {
            callPanel?.present(
                state: state,
                mode: .active,
                hfpConnected: handsFreeBridge.isConnected,
                audioOnMac: false
            )
        }
    }

    private func hangUpCurrentCall() {
        if handsFreeBridge.isConnected {
            handsFreeBridge.hangUp()
        }
        sendActionToAndroid(type: "phone_hangup", text: "hangup", successTooltip: "Ended Android call")
    }

    private func startCallAudioSetupPolling(knownBefore: Set<String>, phoneName: String?) {
        callAudioSetupTimer?.invalidate()
        var attempts = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            attempts += 1
            let namedMatch = phoneName.flatMap { name in
                BluetoothInfo.pairedDeviceAddress(named: [name])
            }
            let current = Set(BluetoothInfo.pairedDeviceAddresses())
            let newDevices = current.subtracting(knownBefore)
            if let phoneAddress = namedMatch ?? newDevices.first ?? self.detectPairedPhoneAddress() {
                timer.invalidate()
                self.callAudioSetupTimer = nil
                self.adoptPhoneForCallAudio(phoneAddress)
                return
            }
            if attempts >= 60 {
                timer.invalidate()
                self.callAudioSetupTimer = nil
                self.showTransientIcon(.error, tooltip: "Call audio setup timed out")
                self.showRetryableError(
                    "Could not find your phone among paired Bluetooth devices. Confirm the pairing prompt on your phone and try again.",
                    retry: { self.setupCallAudio() }
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        callAudioSetupTimer = timer
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

    @objc private func showSettings() {
        closePopover()
        refreshSettings()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: SettingsView(model: settingsViewModel, prefs: prefs))
        let window = NSWindow(contentViewController: host)
        window.title = "Linkit Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 500))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func wireSettingsActions() {
        settingsViewModel.onSetLaunchAtLogin = { [weak self] on in
            self?.setLaunchAtLogin(enabled: on)
            self?.refreshSettings()
        }
        settingsViewModel.onSetClipboardSync = { [weak self] on in
            self?.setClipboardSync(enabled: on)
            self?.refreshSettings()
        }
        settingsViewModel.onDisconnect = { [weak self] id in
            self?.app?.disconnectDevice(id)
            self?.refreshStatusButton()
            self?.refreshPanel()
            self?.refreshSettings()
        }
        settingsViewModel.onForget = { [weak self] id in self?.forgetDevice(id: id) }
        settingsViewModel.onShowQR = { [weak self] in self?.showPairingQR() }
        settingsViewModel.onRevealDropFolder = { [weak self] in self?.revealDropFolder() }
        settingsViewModel.onOpenDropFolder = { [weak self] in self?.openDropFolder() }
        settingsViewModel.onChangeDropFolder = { [weak self] in self?.chooseDropFolder() }
        settingsViewModel.onResetDropFolder = { [weak self] in self?.resetDropFolder() }
        settingsViewModel.onRelaunch = { [weak self] in self?.relaunchApp() }
        settingsViewModel.onOpenRecent = { [weak self] path in self?.openRecentTransferPath(path) }
        settingsViewModel.onOpenLog = { [weak self] in self?.openTransferLog() }
        settingsViewModel.onSetupCallAudio = { [weak self] in self?.setupCallAudio() }
        settingsViewModel.onToggleCallAudioRoute = { [weak self] in self?.toggleCallAudioRoute() }
        settingsViewModel.onCheckUpdates = { [weak self] in self?.checkForUpdates() }
        settingsViewModel.onCopyReport = { [weak self] in self?.copyDiagnosticsReport() }
        settingsViewModel.onRefresh = { [weak self] in self?.refreshSettings() }
    }

    private func refreshSettings() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshSettings() }
            return
        }
        guard let app else { return }
        let connected = app.connectedDevices()
        let connectedIds = Set(connected.map(\.deviceId))
        let byId = Dictionary(connected.map { ($0.deviceId, $0) }, uniquingKeysWith: { first, _ in first })
        settingsViewModel.launchAtLogin = isLaunchAtLoginEnabled
        settingsViewModel.launchAtLoginAvailable = isRunningFromAppBundle
        settingsViewModel.clipboardSyncEnabled = clipboardSyncEnabled
        settingsViewModel.devices = app.trustedDevices().map { device in
            SettingsDeviceRow(
                id: device.deviceId,
                name: device.deviceName,
                platform: device.platform,
                isConnected: connectedIds.contains(device.deviceId),
                batteryPercent: byId[device.deviceId]?.batteryPercent
            )
        }
        settingsViewModel.localIP = LocalNetwork.bestPrivateIPv4()
        settingsViewModel.port = "\(app.configuration.port)"
        settingsViewModel.dropFolderPath = app.dropFolder.path
        settingsViewModel.dropFolderIsCustom = prefs.dropFolderBookmark != nil
        settingsViewModel.canRelaunch = isRunningFromAppBundle
        settingsViewModel.logPath = app.logFile.path
        settingsViewModel.trustedCount = app.trustedDevices().count
        settingsViewModel.recentTransfers = app.recentTransfers(limit: 10).enumerated().map { index, entry in
            RecentTransferRow(
                id: "\(index)-\(entry.filename)",
                filename: entry.filename,
                status: entry.status,
                savedPath: entry.savedPath,
                direction: .unknown
            )
        }
        settingsViewModel.phoneStatus = panelPhoneState().statusText
        settingsViewModel.callAudioStatus = handsFreeBridge.statusLabel
        settingsViewModel.callAudioConfigured = handsFreeBridge.isConnected
        settingsViewModel.callAudioOnMac = handsFreeBridge.audioLocation == .mac
        settingsViewModel.version = appVersionString()
        settingsViewModel.build = appBuildString()
    }

    private func setClipboardSync(enabled: Bool) {
        guard enabled != clipboardSyncEnabled else { return }
        toggleClipboardSync()
    }

    // MARK: Preferences applied at launch

    /// Builds the receiver configuration from saved preferences. Port and drop
    /// folder are applied here (at launch) rather than live, so the bound socket
    /// and transfer store are never rebuilt under a running transfer.
    private func makeReceiverConfiguration() -> ReceiverConfiguration {
        let port = prefs.listenPort
        let portValue: UInt16 = (port > 0 && port <= 65_535) ? UInt16(port) : 52718
        return ReceiverConfiguration(port: portValue, destination: resolvedDropFolder())
    }

    private func resolvedDropFolder() -> URL? {
        guard let data = prefs.dropFolderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func observeAppearance() {
        prefs.$appearance
            .receive(on: RunLoop.main)
            .sink { [weak self] pref in self?.applyAppearance(pref) }
            .store(in: &cancellables)
    }

    private func applyAppearance(_ pref: LinkitAppearancePreference) {
        switch pref {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc private func chooseDropFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where received files are saved"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            prefs.dropFolderBookmark = data
            refreshSettings()
            promptRelaunchToApply(what: "new save location")
        } catch {
            showNonFatalError("Could not set the save location: \(error.localizedDescription)")
        }
    }

    private func resetDropFolder() {
        prefs.dropFolderBookmark = nil
        refreshSettings()
        promptRelaunchToApply(what: "default save location")
    }

    private func promptRelaunchToApply(what: String) {
        let alert = NSAlert()
        alert.messageText = "Relaunch to apply"
        alert.informativeText = "Linkit applies the \(what) when it starts. Relaunch now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: isRunningFromAppBundle ? "Relaunch" : "OK")
        if isRunningFromAppBundle {
            alert.addButton(withTitle: "Later")
        }
        let response = alert.runModal()
        if isRunningFromAppBundle, response == .alertFirstButtonReturn {
            relaunchApp()
        }
    }

    private func relaunchApp() {
        guard isRunningFromAppBundle else { return }
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func forgetDevice(id deviceId: String) {
        guard let app else { return }
        do {
            try app.forgetDevice(deviceId)
            lastTrustedSignature = ""
            lastConnectedSignature = ""
            refreshStatusButton()
            refreshPanel()
            refreshSettings()
        } catch {
            showNonFatalError("Could not forget device: \(error.localizedDescription)")
        }
    }

    private func revealDropFolder() {
        guard let app else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.dropFolder])
    }

    private func copyDiagnosticsReport() {
        guard let app else { return }
        let body = [
            "Linkit \(appVersionString()) (\(appBuildString()))",
            "Status: receiving",
            "IP: \(LocalNetwork.bestPrivateIPv4())",
            "Port: \(app.configuration.port)",
            "Drop: \(app.dropFolder.path)",
            "Trusted devices: \(app.trustedDevices().count)",
            "Log: \(app.logFile.path)",
        ].joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(body, forType: .string)
        showTransientIcon(.success, tooltip: "Diagnostics copied")
    }

    private func appVersionString() -> String {
        appUpdater?.currentVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private func appBuildString() -> String {
        if let appUpdater { return "\(appUpdater.currentBuild)" }
        return (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    private func setLaunchAtLogin(enabled: Bool) {
        guard isRunningFromAppBundle else {
            showNonFatalError("Launch at login is only available from the packaged Linkit.app.")
            refreshPanel()
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
            refreshPanel()
        } catch {
            showNonFatalError("Could not update launch at login: \(error.localizedDescription)")
            refreshPanel()
        }
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
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
        refreshPanel()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        if closedWindow === qrWindow {
            qrWindow = nil
            refreshStatusButton()
        } else if closedWindow === settingsWindow {
            settingsWindow = nil
        } else if closedWindow === callPickerWindow {
            callPickerWindow = nil
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
        dropView.onRightClick = { [weak self] in
            self?.showFallbackMenu()
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
                    self.refreshPanel()
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
                    self.refreshPanel()
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
                    self.refreshPanel()
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
                self?.refreshPanel()
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
        currentPhoneState = state
        handsFreeBridge.connectIfNeeded()
        refreshPanel()

        let panel = ensureCallPanel()
        let hfpConnected = handsFreeBridge.isConnected
        let audioOnMac = handsFreeBridge.audioLocation == .mac

        switch state.state.lowercased() {
        case "ringing":
            showTransientIcon(.pairing, tooltip: "Incoming Android call")
            if !callDismissedByUser {
                panel.present(state: state, mode: .ringing, hfpConnected: hfpConnected, audioOnMac: audioOnMac)
            }
        case "active":
            showTransientIcon(.connected, tooltip: "Android call active")
            if panel.isShown || callAnsweredFromMac {
                panel.present(state: state, mode: .active, hfpConnected: hfpConnected, audioOnMac: audioOnMac)
            }
        default:
            callDismissedByUser = false
            callAnsweredFromMac = false
            panel.close()
        }
    }

    private func ensureCallPanel() -> LinkitCallPanel {
        if let callPanel { return callPanel }
        let panel = LinkitCallPanel()
        panel.onAnswerOnMac = { [weak self] in
            self?.answerCallOnMac()
        }
        panel.onAnswerOnPhone = { [weak self] in
            self?.answerCallOnPhone()
        }
        panel.onAnswer = { [weak self] in
            self?.answerCallOnPhone()
        }
        panel.onDecline = { [weak self] in
            self?.declineAndroidCall()
        }
        panel.onHangup = { [weak self] in
            self?.hangUpCurrentCall()
        }
        panel.onMoveAudio = { [weak self] in
            self?.toggleCallAudioRoute()
        }
        panel.onDismiss = { [weak self] in
            self?.callDismissedByUser = true
        }
        callPanel = panel
        return panel
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
        refreshPanel()

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
        if connected.contains(where: { $0.platform.lowercased() == "android" }) {
            handsFreeBridge.connectIfNeeded()
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
                            self.refreshPanel()
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
        guard prefs.notifyOnTransferComplete else { return }
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
        guard prefs.notifyOnTransferComplete else { return }
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
        updatePanelTransfer(state)
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

    private func updatePanelTransfer(_ state: LinkitTransferPanelState) {
        transferStripClearWorkItem?.cancel()
        panelViewModel.activeTransfer = PanelTransfer(
            title: state.title,
            detail: state.detail,
            progress: state.progress,
            isOutgoing: state.direction == .macToAndroid,
            isActive: state.isActive,
            didFail: state.didFail
        )
        if !state.isActive {
            let work = DispatchWorkItem { [weak self] in self?.panelViewModel.activeTransfer = nil }
            transferStripClearWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
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

private final class LinkitCallPanel {
    private let panel: NSPanel
    private let contentView: LinkitCallPanelView
    private var durationTimer: Timer?
    private var callStartedAt: Date?
    private(set) var isShown = false

    var onAnswer: (() -> Void)?
    var onAnswerOnMac: (() -> Void)?
    var onAnswerOnPhone: (() -> Void)?
    var onDecline: (() -> Void)?
    var onHangup: (() -> Void)?
    var onMoveAudio: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let panelSize = NSSize(width: 340, height: 140)

    init() {
        contentView = LinkitCallPanelView(frame: NSRect(origin: .zero, size: panelSize))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = contentView

        contentView.onAnswer = { [weak self] in self?.onAnswer?() }
        contentView.onAnswerOnMac = { [weak self] in self?.onAnswerOnMac?() }
        contentView.onAnswerOnPhone = { [weak self] in self?.onAnswerOnPhone?() }
        contentView.onDecline = { [weak self] in
            self?.onDecline?()
            self?.close()
        }
        contentView.onHangup = { [weak self] in self?.onHangup?() }
        contentView.onMoveAudio = { [weak self] in self?.onMoveAudio?() }
        contentView.onDismiss = { [weak self] in
            self?.onDismiss?()
            self?.close()
        }
    }

    func present(
        state: AndroidPhoneState,
        mode: LinkitCallPanelMode,
        hfpConnected: Bool,
        audioOnMac: Bool
    ) {
        if mode == .active {
            if callStartedAt == nil {
                callStartedAt = Date()
                startDurationTimer()
            }
        } else {
            stopDurationTimer()
            callStartedAt = nil
        }
        contentView.update(
            state: state,
            mode: mode,
            duration: activeDuration,
            hfpConnected: hfpConnected,
            audioOnMac: audioOnMac
        )
        showIfNeeded()
    }

    func close() {
        stopDurationTimer()
        callStartedAt = nil
        guard isShown else { return }
        animateOut { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.isShown = false
            self.panel.alphaValue = 1
        }
    }

    private var activeDuration: TimeInterval {
        guard let callStartedAt else { return 0 }
        return Date().timeIntervalSince(callStartedAt)
    }

    private func showIfNeeded() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 16
        let size = panelSize
        let targetFrame = NSRect(
            x: screen.visibleFrame.maxX - size.width - margin,
            y: screen.visibleFrame.maxY - size.height - margin,
            width: size.width,
            height: size.height
        )

        if isShown {
            panel.setFrame(targetFrame, display: true)
            return
        }

        var startFrame = targetFrame
        startFrame.origin.x += 40
        panel.alphaValue = 0
        panel.setFrame(startFrame, display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.panel.animator().setFrame(targetFrame, display: true)
            self.panel.animator().alphaValue = 1
        }
        isShown = true
    }

    private func animateOut(completion: @escaping () -> Void) {
        var endFrame = panel.frame
        endFrame.origin.x += 24
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0
            self.panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: completion)
    }

    private func startDurationTimer() {
        durationTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isShown else { return }
            self.contentView.updateDuration(self.activeDuration)
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

private final class LinkitCallPanelView: NSVisualEffectView {
    private let cardView = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let dismissButton = NSButton()
    private let declineButton = NSButton()
    private let answerButton = NSButton()
    private let answerOnMacButton = NSButton()
    private let answerOnPhoneButton = NSButton()
    private let hangupButton = NSButton()
    private let moveAudioButton = NSButton()

    var onAnswer: (() -> Void)?
    var onAnswerOnMac: (() -> Void)?
    var onAnswerOnPhone: (() -> Void)?
    var onDecline: (() -> Void)?
    var onHangup: (() -> Void)?
    var onMoveAudio: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var currentMode: LinkitCallPanelMode = .ringing
    private var hfpConnected = false
    private var audioOnMac = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(
        state: AndroidPhoneState,
        mode: LinkitCallPanelMode,
        duration: TimeInterval,
        hfpConnected: Bool,
        audioOnMac: Bool
    ) {
        currentMode = mode
        self.hfpConnected = hfpConnected
        self.audioOnMac = audioOnMac
        titleLabel.stringValue = state.callPanelTitle
        subtitleLabel.stringValue = state.callPanelSubtitle
        updateStatusLine(duration: duration)

        let accent: NSColor = mode == .ringing ? .systemGreen : .systemBlue
        cardView.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        iconView.layer?.backgroundColor = accent.cgColor
        iconView.image = NSImage(
            systemSymbolName: mode == .ringing ? "phone.arrow.down.left.fill" : "phone.fill",
            accessibilityDescription: nil
        )

        dismissButton.isHidden = mode != .ringing
        declineButton.isHidden = mode != .ringing
        answerButton.isHidden = mode != .ringing || hfpConnected
        answerOnMacButton.isHidden = mode != .ringing || !hfpConnected
        answerOnPhoneButton.isHidden = mode != .ringing || !hfpConnected
        hangupButton.isHidden = mode != .active
        moveAudioButton.isHidden = mode != .active || !hfpConnected

        declineButton.isEnabled = state.canEnd != false
        answerButton.isEnabled = state.canAnswer != false
        answerOnMacButton.isEnabled = state.canAnswer != false
        answerOnPhoneButton.isEnabled = state.canAnswer != false
        hangupButton.isEnabled = state.canEnd != false
        moveAudioButton.title = audioOnMac ? "Move to Phone" : "Move to Mac"

        needsLayout = true
    }

    func updateDuration(_ duration: TimeInterval) {
        guard currentMode == .active else { return }
        updateStatusLine(duration: duration)
    }

    private func updateStatusLine(duration: TimeInterval) {
        switch currentMode {
        case .ringing:
            statusLabel.stringValue = "Incoming call..."
        case .active:
            if hfpConnected {
                let route = audioOnMac ? "On Mac speakers" : "On phone"
                statusLabel.stringValue = "\(route)  \(formatCallDuration(duration))"
            } else {
                statusLabel.stringValue = formatCallDuration(duration)
            }
        }
    }

    private func setup() {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 14
        cardView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.36).cgColor
        cardView.layer?.borderWidth = 1

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        iconView.contentTintColor = .white
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 20
        iconView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.maximumNumberOfLines = 1

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        configureIconButton(dismissButton, symbol: "xmark", color: .secondaryLabelColor.withAlphaComponent(0.35), size: 22, action: #selector(dismissPressed))
        configureIconButton(declineButton, symbol: "phone.down.fill", color: .systemRed, size: 36, action: #selector(declinePressed))
        configureIconButton(answerButton, symbol: "phone.fill", color: .systemGreen, size: 36, action: #selector(answerPressed))
        configureIconButton(answerOnMacButton, symbol: "laptopcomputer", color: .systemGreen, size: 36, action: #selector(answerOnMacPressed))
        configureIconButton(answerOnPhoneButton, symbol: "iphone", color: .systemGreen, size: 36, action: #selector(answerOnPhonePressed))
        configureIconButton(hangupButton, symbol: "phone.down.fill", color: .systemRed, size: 36, action: #selector(hangupPressed))

        moveAudioButton.bezelStyle = .rounded
        moveAudioButton.controlSize = .small
        moveAudioButton.font = .systemFont(ofSize: 10, weight: .medium)
        moveAudioButton.target = self
        moveAudioButton.action = #selector(moveAudioPressed)

        addSubview(cardView)
        [iconView, titleLabel, subtitleLabel, statusLabel, dismissButton, declineButton, answerButton, answerOnMacButton, answerOnPhoneButton, hangupButton, moveAudioButton]
            .forEach(cardView.addSubview)
    }

    private func configureIconButton(_ button: NSButton, symbol: String, color: NSColor, size: CGFloat, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = size / 2
        button.layer?.backgroundColor = color.cgColor
        let pointSize: CGFloat = symbol == "xmark" ? 10 : 15
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        button.imagePosition = .imageOnly
        button.contentTintColor = symbol == "xmark" ? .secondaryLabelColor : .white
        button.target = self
        button.action = action
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 10
        cardView.frame = NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: bounds.height - padding * 2)
        let card = cardView.bounds
        let cardHeight = card.height

        iconView.frame = NSRect(x: 14, y: cardHeight - 54, width: 40, height: 40)
        dismissButton.frame = NSRect(x: card.width - 30, y: cardHeight - 30, width: 22, height: 22)

        let textX: CGFloat = 66
        let textWidth = card.width - textX - 36
        titleLabel.frame = NSRect(x: textX, y: cardHeight - 34, width: textWidth, height: 18)
        subtitleLabel.frame = NSRect(x: textX, y: cardHeight - 52, width: textWidth, height: 15)
        statusLabel.frame = NSRect(x: textX, y: cardHeight - 68, width: textWidth, height: 14)

        declineButton.frame = NSRect(x: card.width - 140, y: 14, width: 36, height: 36)
        answerOnMacButton.frame = NSRect(x: card.width - 96, y: 14, width: 36, height: 36)
        answerOnPhoneButton.frame = NSRect(x: card.width - 52, y: 14, width: 36, height: 36)
        answerButton.frame = NSRect(x: card.width - 52, y: 14, width: 36, height: 36)
        hangupButton.frame = NSRect(x: card.width - 52, y: 14, width: 36, height: 36)
        moveAudioButton.frame = NSRect(x: 66, y: 16, width: 96, height: 22)
    }

    @objc private func answerPressed() { onAnswer?() }
    @objc private func answerOnMacPressed() { onAnswerOnMac?() }
    @objc private func answerOnPhonePressed() { onAnswerOnPhone?() }
    @objc private func declinePressed() { onDecline?() }
    @objc private func hangupPressed() { onHangup?() }
    @objc private func moveAudioPressed() { onMoveAudio?() }
    @objc private func dismissPressed() { onDismiss?() }
}

private func formatCallDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.rounded()))
    return String(format: "%02d:%02d", total / 60, total % 60)
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
    var onRightClick: (() -> Void)?

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

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
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
