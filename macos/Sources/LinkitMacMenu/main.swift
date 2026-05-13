import AppKit
import CoreImage
import LinkitMacCore

final class LinkitMenuDelegate: NSObject, NSApplicationDelegate {
    private var app: LinkitReceiverApp?
    private var statusItem: NSStatusItem?
    private var qrWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?

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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Linkit"
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let app else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Receiving on \(LocalNetwork.bestPrivateIPv4()):\(app.configuration.port)", action: nil, keyEquivalent: ""))
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
        refreshMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
}

let application = NSApplication.shared
let delegate = LinkitMenuDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
