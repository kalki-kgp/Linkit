import AppKit
import CoreImage
import LinkitMacCore

final class LinkitMenuDelegate: NSObject, NSApplicationDelegate {
    private var app: LinkitReceiverApp?
    private var statusItem: NSStatusItem?
    private var qrWindow: NSWindow?

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

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Pairing QR", action: #selector(showPairingQR), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Open Linkit Drop", action: #selector(openDropFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Open Transfer Log", action: #selector(openTransferLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Linkit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func showPairingQR() {
        guard let app else { return }

        let payload = app.pairingPayloadJSON()
        let imageView = NSImageView(frame: NSRect(x: 30, y: 130, width: 320, height: 320))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = qrImage(from: payload, size: 320)

        let title = NSTextField(labelWithString: "Scan with Linkit on Android")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.frame = NSRect(x: 24, y: 465, width: 360, height: 24)

        let ip = LocalNetwork.bestPrivateIPv4()
        let details = NSTextField(labelWithString: "IP \(ip)  Port \(app.configuration.port)")
        details.frame = NSRect(x: 24, y: 438, width: 360, height: 20)

        let payloadField = NSTextField(wrappingLabelWithString: payload)
        payloadField.frame = NSRect(x: 24, y: 20, width: 360, height: 96)
        payloadField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 408, height: 510))
        content.addSubview(title)
        content.addSubview(details)
        content.addSubview(imageView)
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

    @objc private func quit() {
        NSApp.terminate(nil)
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
