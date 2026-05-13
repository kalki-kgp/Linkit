import Foundation

final class BonjourAdvertiser: NSObject, NetServiceDelegate {
    private let port: UInt16
    private let serviceName: String
    private let logger: LinkitLogger
    private var service: NetService?
    private var thread: Thread?

    init(port: UInt16, serviceName: String, logger: LinkitLogger) {
        self.port = port
        self.serviceName = serviceName
        self.logger = logger
    }

    func start() {
        guard thread == nil else { return }

        let thread = Thread { [weak self] in
            self?.publishOnCurrentThread()
        }
        thread.name = "Linkit Bonjour"
        self.thread = thread
        thread.start()
    }

    func stop() {
        service?.stop()
        thread?.cancel()
    }

    private func publishOnCurrentThread() {
        let service = NetService(
            domain: "local.",
            type: "_linkit._tcp.",
            name: serviceName,
            port: Int32(port)
        )
        service.delegate = self
        service.includesPeerToPeer = true
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "v": Data("1".utf8),
            "phase": Data("1".utf8),
            "api": Data("/v1".utf8)
        ]))
        service.schedule(in: .current, forMode: .default)
        self.service = service
        service.publish()

        logger.info("bonjour publish requested type=_linkit._tcp. name=\(serviceName) port=\(port)")
        RunLoop.current.run()
    }

    func netServiceDidPublish(_ sender: NetService) {
        logger.info("bonjour published type=\(sender.type) name=\(sender.name) port=\(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        logger.error("bonjour publish failed type=\(sender.type) name=\(sender.name) error=\(errorDict)")
    }

    func netServiceDidStop(_ sender: NetService) {
        logger.info("bonjour stopped type=\(sender.type) name=\(sender.name)")
    }
}
