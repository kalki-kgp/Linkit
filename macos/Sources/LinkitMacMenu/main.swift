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
    /// Local path of the received file, set only for completed Android→Mac transfers so the
    /// notification can act as a drag source straight into Finder / other apps.
    var savedPath: String? = nil
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

private struct AndroidNotification: Codable {
    let appName: String?
    let title: String?
    let text: String?

    var bannerTitle: String {
        if let title, !title.isEmpty { return title }
        if let appName, !appName.isEmpty { return appName }
        return "Notification"
    }

    var bannerSubtitle: String? {
        text?.isEmpty == false ? text : nil
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
    private var notificationBannerManager: LinkitNotificationBannerManager?
    private var notificationHistory: [MirroredNotificationRow] = []
    private let notificationHistoryLimit = 10
    private var callDismissedByUser = false
    private var callAnsweredFromMac = false
    /// Set when we place a call from the Mac (via the call picker) so the call-status panel
    /// shows on the Mac when Android reports the call going active — even though the Mac, not
    /// the phone, started it.
    private var callInitiatedFromMac = false
    /// Last phone state reported by Android, used to tell an outgoing call placed on the phone
    /// (idle → active, no ringing) from an incoming call answered on the phone (ringing → active).
    private var previousPhoneStateRaw = "idle"
    /// Guards against firing the "call on phone" notification more than once per call session.
    private var notifiedPhoneCallActive = false
    private var notificationCenter: UNUserNotificationCenter?
    /// Cached macOS notification authorization; the system API is async, but the feature-status
    /// provider (called off-main from the HTTP server) needs a synchronous read. Written on the
    /// main thread (launch + periodic sweep) and read on the HTTP server thread, so all access is
    /// serialized through `notificationAuthorizationLock` to avoid a torn/stale cross-thread read.
    private let notificationAuthorizationLock = NSLock()
    private var _notificationAuthorization: UNAuthorizationStatus = .notDetermined
    private var notificationAuthorization: UNAuthorizationStatus {
        get {
            notificationAuthorizationLock.lock()
            defer { notificationAuthorizationLock.unlock() }
            return _notificationAuthorization
        }
        set {
            notificationAuthorizationLock.lock()
            _notificationAuthorization = newValue
            notificationAuthorizationLock.unlock()
        }
    }
    /// One-shot timer that clears an elapsed Do Not Disturb window so the icon
    /// tooltip self-heals without waiting for the next menu open.
    private var doNotDisturbExpiryTimer: Timer?
    private var appUpdater: MacAppUpdater?
    private var updateCheckTimer: Timer?
    /// True while an update check is running, so the launch and timer paths don't overlap.
    private var updateCheckInFlight = false
    /// True from the moment the user accepts an update until it finishes, so a second prompt
    /// (e.g. a manual check racing the auto check) can't start a duplicate install.
    private var installInProgress = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeAppearance()
        configureNotifications()
        appUpdater = try? MacAppUpdater()
        maybeAutoCheckForUpdates()
        // A long-running menu-bar app: re-arm the daily check without needing a relaunch.
        // The method self-throttles to once every 24h, so a 6h cadence is just a heartbeat.
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.maybeAutoCheckForUpdates()
        }
        do {
            let receiver = try LinkitReceiverApp(
                configuration: makeReceiverConfiguration(),
                localFeaturesProvider: { [weak self] in self?.macFeatureStatuses() ?? [] }
            )
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
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        wirePanelActions()
        wireSettingsActions()
        prefs.expireDoNotDisturbIfNeeded()
        scheduleDoNotDisturbExpiry()
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
        var tooltip: String
        if connected.isEmpty {
            tooltip = trusted.isEmpty
                ? "Linkit not paired"
                : "Linkit paired with \(trusted.count), not connected"
        } else {
            tooltip = "Linkit connected to \(connected.count) device\(connected.count == 1 ? "" : "s")"
        }
        if prefs.isDoNotDisturbActive, let until = prefs.doNotDisturbUntil {
            tooltip += " · Do Not Disturb until \(Self.doNotDisturbTimeFormatter.string(from: until))"
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

            // The phone dropped while we were showing call UI: no further phone_state
            // will arrive to close the panel, so clear it here (see teardown docs).
            if hadConnectedSignature && connected.isEmpty {
                teardownCallUIForLostConnection()
            }

            if hadTrustedSignature && !devices.isEmpty && !trustedSignature.isEmpty {
                announcePairing(devices.last)
            } else if !hadConnectedSignature && !connected.isEmpty {
                announceConnection(connected.last)
            }
        }
    }

    /// Tears down the incoming/active call UI when the phone becomes unreachable.
    ///
    /// A call panel raised while connected would otherwise linger forever after a
    /// mid-call disconnect: no further `phone_state` arrives to close it, and the
    /// Hang Up button sends `phone_hangup` to a phone we can no longer reach — so
    /// the only escape was quitting and relaunching the app. Clearing the panel and
    /// resetting the per-call flags here restores a clean state; if the phone comes
    /// back with a call still active it re-pushes `phone_state` and we re-present.
    private func teardownCallUIForLostConnection() {
        guard callPanel?.isShown == true || currentPhoneState != nil else { return }
        callPanel?.close()
        currentPhoneState = nil
        previousPhoneStateRaw = "idle"
        callDismissedByUser = false
        callAnsweredFromMac = false
        callInitiatedFromMac = false
        notifiedPhoneCallActive = false
        refreshPanel()
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
        panelViewModel.peerAttentionCount = androidTargets.first?.features.filter { $0.state == .attention }.count ?? 0
        panelViewModel.clipboardSyncEnabled = clipboardSyncEnabled
        panelViewModel.phone = panelPhoneState()
        panelViewModel.recentTransfers = app.recentTransfers(limit: 8).enumerated().map { index, entry in
            RecentTransferRow(
                id: "\(index)-\(entry.filename)",
                filename: entry.filename,
                status: entry.status,
                savedPath: entry.savedPath,
                direction: .unknown
            )
        }

        // refreshPanel is the universal "state changed" hook (~25 call sites), but the
        // Settings window has its own view model. Keep it live while it's open so changes
        // show without closing and reopening it.
        if settingsWindow != nil {
            refreshSettings()
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
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Make the popover its own key window immediately. Without this the backing
        // vibrancy material renders in its washed-out "inactive" state until the
        // first click inside the popover makes it key.
        popover.contentViewController?.view.window?.makeKey()
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
        prefs.expireDoNotDisturbIfNeeded()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Linkit", action: #selector(togglePopoverAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeDoNotDisturbMenuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Linkit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Builds the "Do Not Disturb" entry for the menu-bar menu: a submenu of
    /// preset quiet-window durations, plus a live "on until …" state and an
    /// off switch when a window is already running.
    private func makeDoNotDisturbMenuItem() -> NSMenuItem {
        let active = prefs.isDoNotDisturbActive
        let item = NSMenuItem(title: "Do Not Disturb", action: nil, keyEquivalent: "")
        item.state = active ? .on : .off

        let submenu = NSMenu()
        if active, let until = prefs.doNotDisturbUntil {
            let status = NSMenuItem(title: "On until \(Self.doNotDisturbTimeFormatter.string(from: until))", action: nil, keyEquivalent: "")
            status.isEnabled = false
            submenu.addItem(status)
            let off = NSMenuItem(title: "Turn Off", action: #selector(disableDoNotDisturb), keyEquivalent: "")
            off.target = self
            submenu.addItem(off)
            submenu.addItem(NSMenuItem.separator())
        }
        for hours in Preferences.doNotDisturbDurations {
            let title = hours == 1 ? "For 1 hour" : "For \(hours) hours"
            let entry = NSMenuItem(title: title, action: #selector(enableDoNotDisturb(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = hours
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// Local time-of-day formatter for the DND "on until …" label.
    private static let doNotDisturbTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    @objc private func enableDoNotDisturb(_ sender: NSMenuItem) {
        guard let hours = sender.representedObject as? Int else { return }
        prefs.doNotDisturbUntil = Date().addingTimeInterval(TimeInterval(hours) * 3600)
        scheduleDoNotDisturbExpiry()
        refreshStatusButton()
        showTransientIcon(.success, tooltip: "Do Not Disturb on")
    }

    @objc private func disableDoNotDisturb() {
        prefs.doNotDisturbUntil = nil
        doNotDisturbExpiryTimer?.invalidate()
        doNotDisturbExpiryTimer = nil
        refreshStatusButton()
        showTransientIcon(.success, tooltip: "Do Not Disturb off")
    }

    /// Arms a one-shot timer that clears DND when the window elapses, so the
    /// status icon and mirrored feature health self-heal without a menu open.
    private func scheduleDoNotDisturbExpiry() {
        doNotDisturbExpiryTimer?.invalidate()
        guard let until = prefs.doNotDisturbUntil else { return }
        let interval = max(1, until.timeIntervalSinceNow)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.prefs.expireDoNotDisturbIfNeeded()
            self.doNotDisturbExpiryTimer = nil
            self.refreshStatusButton()
        }
        timer.tolerance = 30
        doNotDisturbExpiryTimer = timer
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

    /// Normalizes a picked/typed number and asks Android to place the call. The call is flagged
    /// as Mac-initiated so its status surfaces on the Mac when Android reports it going active.
    private func dialNormalizedNumber(_ raw: String) {
        guard let normalized = normalizedDialNumber(raw) else {
            showNonFatalError("Enter a normal phone number with digits and an optional leading +.")
            return
        }
        callInitiatedFromMac = true
        callDismissedByUser = false
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
        callAnsweredFromMac = true
        sendActionToAndroid(type: "phone_answer", text: "answer", successTooltip: "Answered Android call")
        if let state = currentPhoneState {
            callPanel?.present(state: state, mode: .active)
        }
    }

    @objc private func declineAndroidCall() {
        sendActionToAndroid(type: "phone_decline", text: "decline", successTooltip: "Declined Android call")
    }

    @objc private func hangupAndroidCall() {
        hangUpCurrentCall()
    }

    private func hangUpCurrentCall() {
        sendActionToAndroid(type: "phone_hangup", text: "hangup", successTooltip: "Ended Android call")
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

    /// Once-a-day background update check. Runs quietly: only a found update raises the existing
    /// "Update Linkit?" popup — an up-to-date result or a network failure stays silent (unlike the
    /// menu's manual "Check for Updates…", which reports every outcome). Throttled by a stored
    /// timestamp so relaunches within a day don't re-hit GitHub.
    private func maybeAutoCheckForUpdates() {
        guard let appUpdater, !updateCheckInFlight else { return }
        if let last = prefs.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        updateCheckInFlight = true
        Task {
            let result = try? await appUpdater.checkForUpdates()
            await MainActor.run {
                self.updateCheckInFlight = false
                // Record the daily slot only on a definitive result, so an offline launch retries
                // next time instead of skipping the auto-check for the rest of the day.
                guard let result else { return }
                self.prefs.lastUpdateCheck = Date()
                if case let .available(update) = result {
                    self.confirmAndInstall(update, appUpdater: appUpdater)
                }
            }
        }
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
        if installInProgress { return }
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

        installInProgress = true
        showTransientIcon(.transferring(direction: .androidToMac), tooltip: "Installing update")
        Task {
            do {
                try await appUpdater.install(update)
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    self.installInProgress = false
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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
        settingsViewModel.recentNotifications = notificationHistory
        settingsViewModel.peerFeatures = connected
            .first(where: { $0.platform.lowercased() == "android" })?.features ?? []
        settingsViewModel.phoneStatus = panelPhoneState().statusText
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
                    let savedPath = (notification.userInfo?[LinkitTransferNotification.savedPathKey] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 }
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
                            didFail: false,
                            savedPath: savedPath
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
        case "notification":
            handleAndroidNotification(text)
        case "feature_resolve":
            resolveMacFeature(id: text)
        default:
            break
        }
    }

    /// The phone tapped a broken "Your Mac" feature and asked this Mac to fix it. Re-drive the same
    /// permission flow the user would trigger from Settings; once granted, the periodic sweep
    /// refreshes the cached status and the next registration reply flips the phone's dot green.
    private func resolveMacFeature(id: String) {
        switch id {
        case MacFeatureID.transferNotifications:
            promptForNotificationPermission()
        default:
            break
        }
    }

    /// Bring notification permission to the foreground: request it if never asked, otherwise open
    /// the Notifications pane (macOS won't re-prompt once decided), then re-read the status.
    private func promptForNotificationPermission() {
        guard isRunningFromAppBundle, let center = notificationCenter else { return }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                if settings.authorizationStatus == .notDetermined {
                    center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                        self?.refreshNotificationAuthorization()
                    }
                } else {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                    self?.refreshNotificationAuthorization()
                }
                self?.showTransientIcon(.success, tooltip: "Phone asked to enable notifications")
            }
        }
    }

    private func handleAndroidNotification(_ text: String) {
        guard let data = text.data(using: .utf8),
              let notification = try? JSONDecoder().decode(AndroidNotification.self, from: data)
        else { return }
        // Do Not Disturb suppresses the on-screen banner, but the phone
        // notification is still logged to history so nothing is lost.
        if !prefs.isDoNotDisturbActive {
            ensureNotificationBannerManager().present(notification)
        }

        let row = MirroredNotificationRow(
            id: UUID().uuidString,
            title: notification.bannerTitle,
            body: notification.bannerSubtitle ?? "",
            appName: notification.appName ?? "",
            receivedAt: Date()
        )
        notificationHistory.insert(row, at: 0)
        if notificationHistory.count > notificationHistoryLimit {
            notificationHistory.removeLast(notificationHistory.count - notificationHistoryLimit)
        }
        settingsViewModel.recentNotifications = notificationHistory
    }

    private func ensureNotificationBannerManager() -> LinkitNotificationBannerManager {
        if let notificationBannerManager { return notificationBannerManager }
        let manager = LinkitNotificationBannerManager()
        notificationBannerManager = manager
        return manager
    }

    private func handleAndroidPhoneState(_ text: String) {
        guard let data = text.data(using: .utf8),
              let state = try? JSONDecoder().decode(AndroidPhoneState.self, from: data)
        else { return }
        currentPhoneState = state
        refreshPanel()

        let panel = ensureCallPanel()
        let newState = state.state.lowercased()

        switch newState {
        case "ringing":
            showTransientIcon(.pairing, tooltip: "Incoming Android call")
            if !callDismissedByUser {
                panel.present(state: state, mode: .ringing)
            }
        case "active":
            showTransientIcon(.connected, tooltip: "Android call active")
            // A call that goes active without first ringing, and that the Mac didn't place,
            // is a call started on the phone — let the user know on the Mac.
            if previousPhoneStateRaw != "ringing", !callInitiatedFromMac, !notifiedPhoneCallActive {
                postPhoneCallNotification(state: state)
            }
            notifiedPhoneCallActive = true
            if panel.isShown || callAnsweredFromMac || callInitiatedFromMac {
                panel.present(state: state, mode: .active)
            }
        default:
            callDismissedByUser = false
            callAnsweredFromMac = false
            callInitiatedFromMac = false
            notifiedPhoneCallActive = false
            panel.close()
        }
        previousPhoneStateRaw = newState
    }

    private func postPhoneCallNotification(state: AndroidPhoneState) {
        guard !prefs.isDoNotDisturbActive else { return }
        guard let notificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = "Call on your phone"
        let hasName = state.name?.isEmpty == false
        let hasNumber = state.number?.isEmpty == false
        if hasName, hasNumber {
            content.body = "\(state.name!) · \(state.number!)"
        } else if hasName {
            content.body = state.name!
        } else if hasNumber {
            content.body = state.number!
        } else {
            content.body = "A call is active on your Android phone."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "linkit.phonecall.\(UUID().uuidString)", content: content, trigger: nil)
        notificationCenter.add(request, withCompletionHandler: nil)
    }

    private func ensureCallPanel() -> LinkitCallPanel {
        if let callPanel { return callPanel }
        let panel = LinkitCallPanel()
        panel.onAnswer = { [weak self] in
            self?.answerAndroidCall()
        }
        panel.onDecline = { [weak self] in
            self?.declineAndroidCall()
        }
        panel.onHangup = { [weak self] in
            self?.hangUpCurrentCall()
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
        // Re-read macOS notification authorization on the periodic tick so the feature-status we
        // report (and mirror to the phone's "Your Mac" section) self-heals after the user grants
        // permission in System Settings, instead of staying stale until the next relaunch.
        refreshNotificationAuthorization()
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
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshNotificationAuthorization()
        }
        refreshNotificationAuthorization()
        let reveal = UNNotificationAction(identifier: "linkit.reveal", title: "Show in Finder", options: [])
        let open = UNNotificationAction(identifier: "linkit.open", title: "Open", options: [.foreground])
        let category = UNNotificationCategory(identifier: "linkit.receive", actions: [open, reveal], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func refreshNotificationAuthorization() {
        guard let notificationCenter else { return }
        notificationCenter.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async { self?.notificationAuthorization = settings.authorizationStatus }
        }
    }

    /// This Mac's self-reported feature health, shared with the paired Android phone so both apps
    /// render the same two-sided status snapshot. Called off-main from the HTTP server, so it only
    /// reads thread-safe values (UserDefaults-backed prefs, SMAppService status, a cached auth flag).
    func macFeatureStatuses() -> [FeatureStatus] {
        var features: [FeatureStatus] = []

        // Snapshot once: the HTTP server calls this off-main while Settings can toggle the pref on
        // the main thread, so reading it twice could split into an `on` state with an `off` detail.
        let clipboardEnabled = clipboardSyncEnabled
        features.append(FeatureStatus(
            id: MacFeatureID.clipboardSync,
            title: "Clipboard sync",
            state: clipboardEnabled ? .on : .off,
            detail: clipboardEnabled
                ? "Copying Mac clipboard text to your phone."
                : "Turn on to copy Mac clipboard text to your phone."
        ))

        let bundled = isRunningFromAppBundle
        features.append(FeatureStatus(
            id: MacFeatureID.launchAtLogin,
            title: "Launch at login",
            state: !bundled ? .unsupported : (isLaunchAtLoginEnabled ? .on : .off),
            detail: !bundled
                ? "Available when running the packaged Linkit.app."
                : (isLaunchAtLoginEnabled ? "Linkit starts when you log in." : "Turn on to start Linkit when you log in.")
        ))

        let notifState: FeatureState
        let notifDetail: String
        // Snapshot once so a window elapsing mid-read can't split the state and detail.
        let dndUntil = prefs.isDoNotDisturbActive ? prefs.doNotDisturbUntil : nil
        if !bundled {
            notifState = .unsupported
            notifDetail = "Banners require the packaged Linkit.app."
        } else if !prefs.notifyOnTransferComplete {
            notifState = .off
            notifDetail = "Turn on transfer notifications in Settings → General."
        } else if let dndUntil {
            notifState = .off
            notifDetail = "Paused by Do Not Disturb until \(Self.doNotDisturbTimeFormatter.string(from: dndUntil))."
        } else {
            switch notificationAuthorization {
            case .authorized, .provisional, .ephemeral:
                notifState = .on
                notifDetail = "Notifying you when a file arrives."
            case .denied:
                notifState = .attention
                notifDetail = "Allow Linkit notifications in System Settings › Notifications."
            default:
                notifState = .attention
                notifDetail = "Grant notification permission to see transfer banners."
            }
        }
        features.append(FeatureStatus(
            id: MacFeatureID.transferNotifications,
            title: "Transfer notifications",
            state: notifState,
            detail: notifDetail
        ))

        features.append(FeatureStatus(
            id: MacFeatureID.receiver,
            title: "Receiver",
            state: .on,
            detail: "Listening for phone connections on the local network."
        ))

        return features
    }

    private func postReceivedNotification(userInfo: [AnyHashable: Any]?) {
        guard prefs.notifyOnTransferComplete else { return }
        guard !prefs.isDoNotDisturbActive else { return }
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
        guard !prefs.isDoNotDisturbActive else { return }
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
        panel.show(state: state)
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
    private let model = CallPanelModel()
    private var durationTimer: Timer?
    private var callStartedAt: Date?
    private(set) var isShown = false

    var onAnswer: (() -> Void)?
    var onDecline: (() -> Void)?
    var onHangup: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let panelSize = NSSize(width: 320, height: 128)

    init() {
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

        let content = CallPanelContent(
            model: model,
            onAnswer: { [weak self] in self?.onAnswer?() },
            onDecline: { [weak self] in self?.onDecline?(); self?.close() },
            onHangup: { [weak self] in self?.onHangup?() },
            onDismiss: { [weak self] in self?.onDismiss?(); self?.close() }
        )
        panel.contentView = LinkitGlassHostView(rootView: content)
    }

    func present(
        state: AndroidPhoneState,
        mode: LinkitCallPanelMode
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
        model.accent = Preferences.shared.accent
        model.mode = mode
        model.title = state.callPanelTitle
        model.canAnswer = state.canAnswer != false
        model.canEnd = state.canEnd != false
        model.statusText = callStatusLine(mode: mode, duration: activeDuration)
        showIfNeeded()
    }

    private func callStatusLine(mode: LinkitCallPanelMode, duration: TimeInterval) -> String {
        mode == .ringing ? "Incoming call" : formatCallDuration(duration)
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
            self.model.statusText = self.callStatusLine(mode: self.model.mode, duration: self.activeDuration)
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

// MARK: - Floating glass host (shared chrome for call + notification panels)

/// The Linkit "soft green" used for call affordances, matching the popover's `Brand.green`.
private let linkitCallGreen = Color(red: 0.36, green: 0.55, blue: 0.34)

/// Hosts a SwiftUI view inside a frosted, rounded card so the free-floating call and
/// notification panels share the menu-bar app's look (continuous corners, material blur,
/// accent gradients) instead of hand-drawn AppKit chrome.
private final class LinkitGlassHostView<Content: View>: NSVisualEffectView {
    private let hosting: NSHostingView<Content>

    init(rootView: Content) {
        hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var rootView: Content {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }
}

/// A round ✕ glyph button used to dismiss a floating panel.
private struct CloseGlyph: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Call panel content

private final class CallPanelModel: ObservableObject {
    @Published var title = ""
    @Published var statusText = ""
    @Published var mode: LinkitCallPanelMode = .ringing
    @Published var canAnswer = true
    @Published var canEnd = true
    @Published var accent: Color = Preferences.shared.accent
}

private struct CallPanelContent: View {
    @ObservedObject var model: CallPanelModel
    let onAnswer: () -> Void
    let onDecline: () -> Void
    let onHangup: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title.isEmpty ? "Android call" : model.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(model.statusText)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(model.mode == .ringing ? linkitCallGreen : Color.secondary)
                }
                Spacer(minLength: 4)
                if model.mode == .ringing {
                    CloseGlyph(action: onDismiss)
                }
            }
            actionButtons
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var avatar: some View {
        let ringing = model.mode == .ringing
        let tint = ringing ? linkitCallGreen : model.accent
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [tint, tint.opacity(0.6)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 42, height: 42)
            .overlay(
                Image(systemName: ringing ? "phone.arrow.down.left.fill" : "phone.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tint.opacity(0.35), radius: 5, y: 1)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            if model.mode == .ringing {
                CallActionButton(title: "Decline", icon: "phone.down.fill", tint: .red,
                                 enabled: model.canEnd, action: onDecline)
                CallActionButton(title: "Answer", icon: "phone.fill", tint: linkitCallGreen,
                                 enabled: model.canAnswer, action: onAnswer)
            } else {
                CallActionButton(title: "Hang Up", icon: "phone.down.fill", tint: .red,
                                 enabled: model.canEnd, action: onHangup)
            }
        }
    }
}

private struct CallActionButton: View {
    let title: String
    let icon: String
    let tint: Color
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private func formatCallDuration(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.rounded()))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

/// Shows mirrored Android notifications as transient banners pinned to the top-right of the
/// active screen — the same free-floating `NSPanel` style as `LinkitCallPanel`. Each banner
/// auto-dismisses after 10 seconds (or immediately when the user taps its ✕), and the manager
/// stacks several downward, re-flowing the stack as banners come and go.
private final class LinkitNotificationBannerManager {
    private var banners: [LinkitNotificationBanner] = []
    private let bannerWidth: CGFloat = 360
    private let margin: CGFloat = 16
    private let spacing: CGFloat = 10
    private let maxVisible = 4

    func present(_ notification: AndroidNotification) {
        let banner = LinkitNotificationBanner(width: bannerWidth)
        banner.configure(notification)
        banner.onDismiss = { [weak self, weak banner] in
            guard let self, let banner else { return }
            self.remove(banner)
        }
        banner.onLayoutChanged = { [weak self] in self?.layout() }
        if let screen = NSScreen.main {
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - bannerWidth - margin,
                y: screen.visibleFrame.maxY - banner.height - margin
            )
            banner.prepareForDisplay(at: origin)
        }
        banners.insert(banner, at: 0)
        while banners.count > maxVisible {
            let overflow = banners.removeLast()
            overflow.dismiss()
        }
        layout()
        banner.startTimer()
    }

    private func remove(_ banner: LinkitNotificationBanner) {
        guard let index = banners.firstIndex(where: { $0 === banner }) else { return }
        banners.remove(at: index)
        banner.dismiss()
        layout()
    }

    /// Re-flow the stack from the top, honoring each banner's own (possibly expanded) height.
    private func layout() {
        guard let screen = NSScreen.main else { return }
        let x = screen.visibleFrame.maxX - bannerWidth - margin
        var topEdge = screen.visibleFrame.maxY - margin
        for banner in banners {
            let originY = topEdge - banner.height
            banner.move(to: NSPoint(x: x, y: originY), animated: true)
            topEdge = originY - spacing
        }
    }
}

private final class LinkitNotificationBanner {
    private let panel: NSPanel
    private let hostView: LinkitGlassHostView<NotificationBannerContent>
    private let width: CGFloat
    private var timer: Timer?
    private var isClosing = false

    // Content + presentation state.
    private var title = ""
    private var bodyText = ""
    private var appName = ""
    private var canExpand = false
    private var expanded = false

    private(set) var height: CGFloat = 100

    var onDismiss: (() -> Void)?
    var onLayoutChanged: (() -> Void)?

    init(width: CGFloat) {
        self.width = width
        let placeholder = NotificationBannerContent(
            title: "", message: "", appName: "", accent: Preferences.shared.accent,
            expanded: false, canExpand: false, onInteract: {}, onClose: {}
        )
        hostView = LinkitGlassHostView(rootView: placeholder)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hostView
    }

    func configure(_ notification: AndroidNotification) {
        title = notification.bannerTitle
        bodyText = notification.bannerSubtitle ?? ""
        appName = notification.appName ?? ""
        canExpand = !bodyText.isEmpty && fullBodyHeight() > collapsedBodyHeight() + 1
        expanded = false
        height = computeHeight()
        resizePanelToHeight()
        refreshContent()
    }

    private func refreshContent() {
        hostView.rootView = NotificationBannerContent(
            title: title,
            message: bodyText,
            appName: appName,
            accent: Preferences.shared.accent,
            expanded: expanded,
            canExpand: canExpand,
            onInteract: { [weak self] in self?.handleInteract() },
            onClose: { [weak self] in self?.onDismiss?() }
        )
    }

    /// Any click on the banner pins it open (cancels auto-dismiss) and toggles the expanded
    /// view when there's more content to reveal.
    private func handleInteract() {
        cancelTimer()
        guard canExpand else { return }
        expanded.toggle()
        height = computeHeight()
        resizePanelToHeight()
        refreshContent()
        onLayoutChanged?()
    }

    private func resizePanelToHeight() {
        let origin = panel.frame.origin
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: false)
    }

    // MARK: Height measurement

    // Matches the SwiftUI text column: full width minus padding, icon, gaps, and the ✕ column.
    // Measured a hair narrower than the real column so the estimate never under-counts lines.
    private var bodyWidth: CGFloat { width - 114 }
    private let bodyLineHeight: CGFloat = 16

    private func fullBodyHeight() -> CGFloat {
        guard !bodyText.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 12)
        let rect = (bodyText as NSString).boundingRect(
            with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    private func collapsedBodyHeight() -> CGFloat {
        bodyText.isEmpty ? 0 : min(fullBodyHeight(), bodyLineHeight * 2)
    }

    private func computeHeight() -> CGFloat {
        let titleHeight: CGFloat = 18
        let sourceVisible = !appName.isEmpty && appName != title
        let footerHeight: CGFloat = (sourceVisible || canExpand) ? 15 : 0
        let body = expanded ? min(fullBodyHeight(), bodyLineHeight * 14) : collapsedBodyHeight()
        var h: CGFloat = 14 + titleHeight + 14
        if body > 0 { h += 4 + body + 4 }
        if footerHeight > 0 { h += 3 + footerHeight }
        return max(h, 72)
    }

    func prepareForDisplay(at origin: NSPoint) {
        var start = NSRect(origin: origin, size: NSSize(width: width, height: height))
        start.origin.x += 40
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
    }

    func move(to origin: NSPoint, animated: Bool) {
        guard !isClosing else { return }
        let target = NSRect(origin: origin, size: NSSize(width: width, height: height))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().setFrame(target, display: true)
                self.panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(target, display: true)
            panel.alphaValue = 1
        }
    }

    func startTimer() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.onDismiss?()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    func dismiss() {
        cancelTimer()
        guard !isClosing else { return }
        isClosing = true
        var end = panel.frame
        end.origin.x += 24
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0
            self.panel.animator().setFrame(end, display: true)
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }
}

private struct NotificationBannerContent: View {
    let title: String
    let message: String
    let appName: String
    let accent: Color
    let expanded: Bool
    let canExpand: Bool
    let onInteract: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [accent, accent.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "bell.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: accent.opacity(0.35), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                }
                if showSource || canExpand {
                    HStack(spacing: 5) {
                        if showSource {
                            Text(appName)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if canExpand {
                            HStack(spacing: 3) {
                                Text(expanded ? "Show less" : "Show more")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(accent)
                        }
                    }
                }
            }

            CloseGlyph(action: onClose)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { onInteract() }
    }

    private var showSource: Bool { !appName.isEmpty && appName != title }
}

/// Transparent overlay that turns a received-file notification into a drag source. When
/// `fileURL` is set it begins a copy drag of that file (icon follows the cursor) so the user
/// can drop it straight into Finder or another app; when nil it ignores hit-testing entirely
/// so underlying controls (e.g. the Cancel button) keep working.
private final class DraggableFileView: NSView, NSDraggingSource {
    var fileURL: URL? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        fileURL == nil ? nil : super.hitTest(point)
    }

    override func resetCursorRects() {
        if fileURL != nil {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = fileURL else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 56, height: 56)
        icon.size = size
        let location = convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: location.x - size.width / 2, y: location.y - size.height / 2, width: size.width, height: size.height)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(frame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy]
    }
}

/// SwiftUI wrapper that turns a list row into a real file drag source. SwiftUI's `.onDrag`
/// doesn't fire inside a `Button` (and is flaky inside a transient popover), so we drop down
/// to the same AppKit `NSDraggingSource` approach the transfer panel uses. A click that
/// doesn't move counts as a tap and calls `onOpen`; a click that drags begins a copy drag.
struct FileDragOverlay: NSViewRepresentable {
    let url: URL?
    let onOpen: () -> Void

    func makeNSView(context: Context) -> FileDragRowView {
        let view = FileDragRowView()
        view.fileURL = url
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ view: FileDragRowView, context: Context) {
        view.fileURL = url
        view.onOpen = onOpen
    }
}

final class FileDragRowView: NSView, NSDraggingSource {
    var fileURL: URL?
    var onOpen: (() -> Void)?
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    // Pass clicks through when there's no file (disabled row); otherwise own the row so we
    // can tell a tap from a drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        fileURL == nil ? nil : super.hitTest(point)
    }

    override func resetCursorRects() {
        if fileURL != nil { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = fileURL, let start = mouseDownPoint, !didDrag else { return }
        let current = event.locationInWindow
        if abs(current.x - start.x) < 4, abs(current.y - start.y) < 4 { return }
        didDrag = true
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 48, height: 48)
        icon.size = size
        let location = convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: location.x - size.width / 2, y: location.y - size.height / 2, width: size.width, height: size.height)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(frame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onOpen?() }
        didDrag = false
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy]
    }
}

/// A floating notification panel for transfer progress / completion. Uses the same
/// free-floating `NSPanel` approach as `LinkitCallPanel` (status-bar window level,
/// joins all spaces and floats over full-screen apps) so it always appears pinned to the
/// top-right of the active screen — consistent whether or not another app owns the menu bar.
private final class LinkitTransferPanel {
    private let panel: NSPanel
    private let content: LinkitTransferPanelView
    private var closeWorkItem: DispatchWorkItem?
    private var isShown = false
    private let panelSize = NSSize(width: 340, height: 150)

    var onCancel: (() -> Void)? {
        get { content.onCancel }
        set { content.onCancel = newValue }
    }

    init() {
        content = LinkitTransferPanelView(frame: NSRect(origin: .zero, size: panelSize))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = content
        content.onClose = { [weak self] in self?.dismiss() }
    }

    /// Manual dismissal (the close button); cancels any pending auto-dismiss first.
    func dismiss() {
        closeWorkItem?.cancel()
        close()
    }

    func show(state: LinkitTransferPanelState) {
        closeWorkItem?.cancel()
        content.transferState = state
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 16
        let targetFrame = NSRect(
            x: screen.visibleFrame.maxX - panelSize.width - margin,
            y: screen.visibleFrame.maxY - panelSize.height - margin,
            width: panelSize.width,
            height: panelSize.height
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

    func closeAfterDelay(_ delay: TimeInterval) {
        closeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.close() }
        closeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func close() {
        guard isShown else { return }
        var endFrame = panel.frame
        endFrame.origin.x += 24
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0
            self.panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.isShown = false
            self.panel.alphaValue = 1
        })
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
    private let closeButton = NSButton()
    private let dragOverlay = DraggableFileView()
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

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

    private func setup() {
        material = .hudWindow
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

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Dismiss"
        closeButton.target = self
        closeButton.action = #selector(closePressed)

        [titleLabel, cardView, closeButton].forEach(addSubview)
        [iconView, transferTitle, transferDetail, transferStats, percentLabel, progressBar, cancelButton].forEach(cardView.addSubview)
        // Topmost so it can intercept drags; transparent to hit-testing unless a file is set.
        cardView.addSubview(dragOverlay)
        updateContent()
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 14
        titleLabel.frame = NSRect(x: padding, y: bounds.height - 32, width: bounds.width - padding * 2, height: 20)
        closeButton.frame = NSRect(x: bounds.width - 30, y: bounds.height - 30, width: 18, height: 18)

        let cardHeight: CGFloat = 96
        cardView.frame = NSRect(x: padding, y: 14, width: bounds.width - padding * 2, height: cardHeight)
        iconView.frame = NSRect(x: 15, y: cardHeight - 58, width: 40, height: 40)
        percentLabel.frame = NSRect(x: cardView.bounds.width - 55, y: cardHeight - 38, width: 38, height: 14)
        transferTitle.frame = NSRect(x: 66, y: cardHeight - 36, width: cardView.bounds.width - 130, height: 17)
        transferDetail.frame = NSRect(x: 66, y: cardHeight - 55, width: cardView.bounds.width - 82, height: 14)
        transferStats.frame = NSRect(x: 66, y: cardHeight - 73, width: cardView.bounds.width - 142, height: 13)
        cancelButton.frame = NSRect(x: cardView.bounds.width - 66, y: 28, width: 50, height: 24)
        progressBar.frame = NSRect(x: 66, y: 13, width: cardView.bounds.width - 82, height: 5)
        dragOverlay.frame = cardView.bounds
    }

    private func updateContent() {
        cardView.layer?.borderColor = accentColor.withAlphaComponent(transferState.isActive ? 0.9 : 0.45).cgColor

        // A completed Android→Mac file can be dragged straight out of the notification.
        let draggableURL: URL? = (!transferState.isActive && !transferState.didFail)
            ? transferState.savedPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            : nil
        dragOverlay.fileURL = draggableURL
        window?.invalidateCursorRects(for: dragOverlay)

        if let url = draggableURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 40, height: 40)
            iconView.image = icon
            iconView.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            iconView.layer?.backgroundColor = accentColor.cgColor
            iconView.image = NSImage(systemSymbolName: transferState.direction == .androidToMac ? "arrow.down" : "arrow.up", accessibilityDescription: nil)
        }
        transferTitle.stringValue = transferState.title
        transferDetail.stringValue = draggableURL != nil ? "\(transferState.detail) · drag to save anywhere" : transferState.detail
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

    @objc private func closePressed() {
        onClose?()
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
