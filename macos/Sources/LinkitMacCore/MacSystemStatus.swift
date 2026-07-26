import CoreWLAN
import Foundation
import IOKit.ps

/// A snapshot of this Mac's live condition, sent down to the phone on every receiver
/// registration so Android can show the same kind of at-a-glance device card the Mac shows
/// for the phone (which reports `batteryPercent` in the opposite direction).
///
/// Every field is optional because none of them exist on every Mac: a Mac mini has no
/// battery, an Ethernet-only Mac has no Wi-Fi RSSI, and a peer running an older build sends
/// nothing at all. The phone renders "—" rather than guessing.
public struct MacSystemStatus: Codable, Equatable {
    /// 0–100, or nil on a desktop Mac with no internal battery.
    public let batteryPercent: Int?
    /// True only while the battery is actually taking charge — a full battery on AC is `false`.
    public let isCharging: Bool?
    /// `"ac"` or `"battery"`. Present even when `batteryPercent` is nil, so the phone can still
    /// say "Plugged in" for a desktop Mac.
    public let powerSource: String?
    public let minutesToFull: Int?
    public let minutesToEmpty: Int?
    public let lowPowerMode: Bool
    /// `"wifi"`, `"ethernet"`, or `"other"`.
    public let networkKind: String?
    /// Raw RSSI in dBm (always negative). Nil when the Mac is not on Wi-Fi or the radio
    /// declined to report — the phone shows the plain link kind in that case.
    public let wifiRssi: Int?
    /// Bucketed `wifiRssi`: `"excellent" | "good" | "fair" | "weak"`.
    public let wifiQuality: String?
    /// Space left on the volume holding the drop folder — the number that decides whether the
    /// next big send will fit.
    public let freeDiskBytes: Int64?
    public let totalDiskBytes: Int64?
    /// Linkit's own Do Not Disturb window, which suppresses mirrored phone notifications.
    public let doNotDisturb: Bool
    /// Marketing-style short version, e.g. `"macOS 26.4"`.
    public let osVersion: String?

    public init(
        batteryPercent: Int?,
        isCharging: Bool?,
        powerSource: String?,
        minutesToFull: Int?,
        minutesToEmpty: Int?,
        lowPowerMode: Bool,
        networkKind: String?,
        wifiRssi: Int?,
        wifiQuality: String?,
        freeDiskBytes: Int64?,
        totalDiskBytes: Int64?,
        doNotDisturb: Bool,
        osVersion: String?
    ) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.powerSource = powerSource
        self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty
        self.lowPowerMode = lowPowerMode
        self.networkKind = networkKind
        self.wifiRssi = wifiRssi
        self.wifiQuality = wifiQuality
        self.freeDiskBytes = freeDiskBytes
        self.totalDiskBytes = totalDiskBytes
        self.doNotDisturb = doNotDisturb
        self.osVersion = osVersion
    }
}

/// Reads ``MacSystemStatus`` from the OS.
///
/// Everything here is a read-only system query that needs no entitlement and no user consent.
/// Wi-Fi RSSI is worth a note: since macOS 14 the *SSID* and *BSSID* are gated behind Location
/// authorization, but signal strength is not, so quality works without ever prompting — and
/// Linkit deliberately never asks for the network name.
public enum MacSystemStatusReader {
    /// Registration refreshes land every ~20s per device, and a couple of peers plus a retry can
    /// bunch several calls into the same moment. Caching briefly keeps that from turning into
    /// repeated IOKit/CoreWLAN/stat work for an answer that cannot have changed.
    private static let cacheLifetime: TimeInterval = 5

    private static let lock = NSLock()
    private static var cached: (status: MacSystemStatus, at: Date, doNotDisturb: Bool)?

    /// - Parameters:
    ///   - doNotDisturb: Linkit's DND state, which lives in the menu app's preferences rather
    ///     than in the OS, so the caller has to supply it.
    ///   - dropFolder: the volume to measure free space on.
    public static func current(doNotDisturb: Bool, dropFolder: URL) -> MacSystemStatus {
        lock.lock()
        if let cached,
           cached.doNotDisturb == doNotDisturb,
           Date().timeIntervalSince(cached.at) < cacheLifetime {
            let status = cached.status
            lock.unlock()
            return status
        }
        lock.unlock()

        let power = readPower()
        let wifi = readWifi()
        let disk = readDisk(at: dropFolder)
        let status = MacSystemStatus(
            batteryPercent: power.percent,
            isCharging: power.isCharging,
            powerSource: power.source,
            minutesToFull: power.minutesToFull,
            minutesToEmpty: power.minutesToEmpty,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            networkKind: wifi.kind,
            wifiRssi: wifi.rssi,
            wifiQuality: wifi.quality,
            freeDiskBytes: disk.free,
            totalDiskBytes: disk.total,
            doNotDisturb: doNotDisturb,
            osVersion: shortOSVersion()
        )

        lock.lock()
        cached = (status, Date(), doNotDisturb)
        lock.unlock()
        return status
    }

    // MARK: - Power

    private struct Power {
        var percent: Int?
        var isCharging: Bool?
        var source: String?
        var minutesToFull: Int?
        var minutesToEmpty: Int?
    }

    private static func readPower() -> Power {
        var power = Power()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return power
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int,
               max > 0 {
                power.percent = Int((Double(current) / Double(max) * 100).rounded()).clampedToPercent()
            }
            power.isCharging = description[kIOPSIsChargingKey] as? Bool
            power.source = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                ? "ac"
                : "battery"
            // IOKit reports these as 0 when not applicable and -1 while it is still estimating;
            // both mean "no useful number", so don't pass them on.
            power.minutesToFull = (description["Time to Full Charge"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            power.minutesToEmpty = (description[kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            break
        }

        // A desktop Mac has no internal battery entry at all, but it is still on wall power, and
        // saying so is more useful to the phone than showing nothing.
        if power.source == nil, sources.isEmpty { power.source = "ac" }
        return power
    }

    // MARK: - Network

    private struct Wifi {
        var kind: String?
        var rssi: Int?
        var quality: String?
    }

    private static func readWifi() -> Wifi {
        var wifi = Wifi()
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            // No usable Wi-Fi radio: the Mac is reachable, so it is on something else.
            wifi.kind = "ethernet"
            return wifi
        }
        wifi.kind = "wifi"

        // 0 is CoreWLAN's "no measurement" sentinel (also what an associated-but-idle radio
        // returns); a real reading is always negative dBm.
        let rssi = interface.rssiValue()
        guard rssi < 0 else { return wifi }
        wifi.rssi = rssi
        wifi.quality = quality(forRSSI: rssi)
        return wifi
    }

    /// Standard Wi-Fi signal buckets. -50 and better is a strong local link, below -75 is where
    /// throughput starts falling off a cliff.
    static func quality(forRSSI rssi: Int) -> String {
        switch rssi {
        case (-50)...: return "excellent"
        case (-65)..<(-50): return "good"
        case (-75)..<(-65): return "fair"
        default: return "weak"
        }
    }

    // MARK: - Disk

    private static func readDisk(at url: URL) -> (free: Int64?, total: Int64?) {
        // The drop folder may not exist yet on a fresh install; its volume still does, so walk up
        // to a path that resolves rather than reporting nothing.
        let probe = FileManager.default.fileExists(atPath: url.path)
            ? url
            : FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        ) else {
            return (nil, nil)
        }
        return (
            values.volumeAvailableCapacityForImportantUsage,
            values.volumeTotalCapacity.map(Int64.init)
        )
    }

    // MARK: - OS

    private static func shortOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // Patch releases are noise on a phone-sized card — "macOS 26.4" is the useful precision.
        return "macOS \(version.majorVersion).\(version.minorVersion)"
    }
}

private extension Int {
    func clampedToPercent() -> Int { Swift.min(100, Swift.max(0, self)) }
}
