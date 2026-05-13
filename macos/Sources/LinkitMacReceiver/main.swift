import Foundation
import LinkitMacCore

let arguments = CommandLine.arguments.dropFirst()
var port: UInt16 = 52718
var destination: URL?
var advertiseBonjour = true
var allowDevBearerTransfers = false

var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--port":
        guard let value = iterator.next(), let parsed = UInt16(value) else {
            fputs("Invalid --port value\n", stderr)
            exit(2)
        }
        port = parsed
    case "--destination":
        guard let value = iterator.next() else {
            fputs("Missing --destination value\n", stderr)
            exit(2)
        }
        destination = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    case "--no-bonjour":
        advertiseBonjour = false
    case "--allow-dev-transfers":
        allowDevBearerTransfers = true
    case "--help", "-h":
        print("""
        LinkitMacReceiver

        Options:
          --port <port>              Listen port. Default: 52718
          --destination <path>       Drop folder. Default: ~/Downloads/Linkit Drop
          --no-bonjour               Disable _linkit._tcp Bonjour advertisement
          --allow-dev-transfers      Allow old bearer-token transfer endpoints
        """)
        exit(0)
    default:
        fputs("Unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

do {
    let config = ReceiverConfiguration(
        port: port,
        destination: destination,
        advertiseBonjour: advertiseBonjour,
        allowDevBearerTransfers: allowDevBearerTransfers
    )
    let app = try LinkitReceiverApp(configuration: config)

    print("Linkit receiver listening on http://0.0.0.0:\(config.port)")
    print("Drop folder: \(app.dropFolder.path)")
    print("Debug log: \(app.logFile.path)")
    print("Device id: \(app.identity.deviceId)")
    print("Dev token: \(app.devToken)")
    print("Bonjour: \(config.advertiseBonjour ? "_linkit._tcp.local." : "disabled")")
    print("Pairing payload: \(app.pairingPayloadJSON())")
    print("Keep this process running while sending from Android.")
    fflush(stdout)

    try app.run()
} catch {
    fputs("Linkit receiver failed: \(error)\n", stderr)
    exit(1)
}
