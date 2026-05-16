import AppKit
import CoreImage
import LinkitMacCore

final class LinkitMenuDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var app: LinkitReceiverApp?
    private var statusItem: NSStatusItem?
    private var statusIcon: StatusIconAnimator?
    private var qrWindow: NSWindow?
    private var retiredWindows: [NSWindow] = []
    private var diagnosticsWindow: NSWindow?
    private var resetStatusWorkItem: DispatchWorkItem?
    private var pairingPoller: DispatchSourceTimer?
    private var transferObservers: [NSObjectProtocol] = []
    private var lastTrustedSignature: String = ""
    private var lastConnectedSignature: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        startPairingPoller()
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

    private func startPairingPoller() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.checkForTrustChanges()
        }
        timer.resume()
        pairingPoller = timer
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
                let item = NSMenuItem(title: "  \(device.deviceName) (\(device.platform))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
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
        menu.addItem(NSMenuItem(title: "Show Pairing QR", action: #selector(showPairingQR), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Open Linkit Drop", action: #selector(openDropFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Diagnostics", action: #selector(showDiagnostics), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Open Transfer Log", action: #selector(openTransferLog), keyEquivalent: "l"))
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

    @objc private func openDropFolder() {
        guard let app else { return }
        NSWorkspace.shared.open(app.dropFolder)
    }

    @objc private func openTransferLog() {
        guard let app else { return }
        NSWorkspace.shared.open(app.logFile)
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

    @objc private func openRecentTransfer(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func refreshMenuAction() {
        checkForTrustChanges()
        refreshMenu()
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

    @objc private func quit() {
        pairingPoller?.cancel()
        pairingPoller = nil
        transferObservers.forEach(NotificationCenter.default.removeObserver)
        transferObservers.removeAll()
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkForTrustChanges()
        refreshMenu()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow, closedWindow === qrWindow else { return }
        qrWindow = nil
        refreshStatusButton()
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
        statusIcon?.setState(.transferring(direction: .macToAndroid), tooltip: "Sending to Android")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let results = try app.sendFilesToFirstAndroid(urls)
                DispatchQueue.main.async {
                    self.showTransientIcon(.success, tooltip: "Sent \(results.count) file\(results.count == 1 ? "" : "s")")
                    self.refreshMenu()
                }
            } catch {
                DispatchQueue.main.async {
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
                let suffix = filename.map { ": \($0)" } ?? ""
                self?.statusIcon?.setState(.transferring(direction: .androidToMac), tooltip: "Receiving from Android\(suffix)")
            }
        )

        transferObservers.append(
            NotificationCenter.default.addObserver(
                forName: .linkitTransferDidFinish,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let status = notification.userInfo?[LinkitTransferNotification.statusKey] as? String
                if status == "complete" {
                    self?.showTransientIcon(.success, tooltip: "Transfer complete")
                } else if status == "canceled" {
                    self?.refreshStatusButton()
                } else {
                    self?.showTransientIcon(.error, tooltip: "Transfer failed")
                }
                self?.refreshMenu()
            }
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
