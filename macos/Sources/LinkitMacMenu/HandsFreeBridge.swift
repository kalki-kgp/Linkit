import Foundation
import IOBluetooth

enum HandsFreeBridgeState: Equatable {
    case notSetUp
    case disconnected
    case connecting
    case connected
}

enum HandsFreeAudioLocation: Equatable {
    case phone
    case mac
}

final class HandsFreeBridge: NSObject {
    static let shared = HandsFreeBridge()

    private let phoneAddressKey = "linkit.phoneBluetoothAddress"
    private var hfDevice: IOBluetoothHandsFreeDevice?
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0

    private(set) var state: HandsFreeBridgeState = .notSetUp
    private(set) var audioLocation: HandsFreeAudioLocation = .phone
    var onStateChange: (() -> Void)?

    var isConnected: Bool { state == .connected }
    var isSetUp: Bool { savedPhoneAddress() != nil }

    var statusLabel: String {
        switch state {
        case .notSetUp:
            return "Call audio: not set up"
        case .disconnected:
            return "Call audio: phone away"
        case .connecting:
            return "Call audio: connecting"
        case .connected:
            return audioLocation == .mac ? "Call audio: on Mac" : "Call audio: connected"
        }
    }

    private override init() {
        super.init()
        if savedPhoneAddress() != nil {
            state = .disconnected
        }
    }

    func savedPhoneAddress() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: phoneAddressKey) else { return nil }
        return BluetoothInfo.normalize(raw)
    }

    func setPhoneAddress(_ address: String) {
        guard let normalized = BluetoothInfo.normalize(address) else { return }
        UserDefaults.standard.set(normalized, forKey: phoneAddressKey)
        state = .disconnected
        notifyStateChange()
        connect()
    }

    func clearPhoneAddress() {
        disconnect()
        UserDefaults.standard.removeObject(forKey: phoneAddressKey)
        state = .notSetUp
        notifyStateChange()
    }

    func connectIfNeeded() {
        guard savedPhoneAddress() != nil else { return }
        if state == .connected || state == .connecting { return }
        connect()
    }

    func connect() {
        reconnectWorkItem?.cancel()
        guard let address = savedPhoneAddress(),
              let device = BluetoothInfo.pairedDevice(for: address)
        else {
            state = savedPhoneAddress() == nil ? .notSetUp : .disconnected
            notifyStateChange()
            return
        }

        state = .connecting
        notifyStateChange()

        if let existing = hfDevice, existing.device?.addressString == device.addressString {
            existing.connect()
            return
        }

        hfDevice?.disconnect()
        guard let next = IOBluetoothHandsFreeDevice(device: device, delegate: self) else {
            state = .disconnected
            notifyStateChange()
            return
        }
        hfDevice = next
        next.connect()
        fputs("Linkit HFP: connecting to \(address)\n", stderr)
        startConnectTimeout()
    }

    private func startConnectTimeout() {
        connectTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .connecting else { return }
            fputs("Linkit HFP: connect timed out\n", stderr)
            self.state = .disconnected
            self.scheduleReconnect()
            self.notifyStateChange()
        }
        connectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        connectTimeoutWorkItem?.cancel()
        hfDevice?.disconnect()
        hfDevice = nil
        if savedPhoneAddress() != nil {
            state = .disconnected
        } else {
            state = .notSetUp
        }
        notifyStateChange()
    }

    func answerOnMac() {
        hfDevice?.acceptCall()
        audioLocation = .mac
        notifyStateChange()
    }

    func answerOnPhone() {
        hfDevice?.acceptCallOnPhone()
        audioLocation = .phone
        notifyStateChange()
    }

    func hangUp() {
        hfDevice?.endCall()
    }

    func moveAudioToMac() {
        hfDevice?.transferAudioToComputer()
        audioLocation = .mac
        notifyStateChange()
    }

    func moveAudioToPhone() {
        hfDevice?.transferAudioToPhone()
        audioLocation = .phone
        notifyStateChange()
    }

    func dial(_ number: String) -> Bool {
        guard let hfDevice, state == .connected else { return false }
        hfDevice.dialNumber(number)
        return true
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        guard savedPhoneAddress() != nil else { return }
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 4))))
        let work = DispatchWorkItem { [weak self] in
            self?.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func notifyStateChange() {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?()
        }
    }
}

extension HandsFreeBridge: IOBluetoothHandsFreeDeviceDelegate {
    // status is an IOReturn: 0 means the service-level connection succeeded.
    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        let success = (status?.int32Value ?? -1) == 0
        fputs("Linkit HFP: connected status=\(status?.int32Value ?? -1)\n", stderr)
        connectTimeoutWorkItem?.cancel()
        if success {
            state = .connected
            reconnectAttempt = 0
        } else if savedPhoneAddress() != nil {
            state = .disconnected
            scheduleReconnect()
        }
        notifyStateChange()
    }

    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        fputs("Linkit HFP: disconnected status=\(status?.int32Value ?? -1)\n", stderr)
        connectTimeoutWorkItem?.cancel()
        if savedPhoneAddress() != nil {
            state = .disconnected
            scheduleReconnect()
        }
        notifyStateChange()
    }

    // SCO is the audio link: open = call audio flowing through the Mac.
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        fputs("Linkit HFP: SCO opened status=\(status?.int32Value ?? -1)\n", stderr)
        if (status?.int32Value ?? -1) == 0 {
            audioLocation = .mac
            notifyStateChange()
        }
    }

    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        fputs("Linkit HFP: SCO closed status=\(status?.int32Value ?? -1)\n", stderr)
        audioLocation = .phone
        notifyStateChange()
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isServiceAvailable: NSNumber!) {
        fputs("Linkit HFP: serviceAvailable=\(isServiceAvailable?.boolValue == true)\n", stderr)
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive callActive: NSNumber!) {
        fputs("Linkit HFP: isCallActive=\(callActive?.boolValue == true)\n", stderr)
    }

    func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        fputs("Linkit HFP: incoming from \(number ?? "unknown")\n", stderr)
    }
}
