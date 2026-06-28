import SwiftUI

extension Preferences {
    /// The user-chosen primary accent for Linkit's own UI (popover, call picker, …).
    /// Falls back to the shipped amber if the stored hex is somehow unparseable.
    var accent: Color {
        Color(hexString: accentColorHex) ?? LinkitAccent.default.color
    }
}

/// A named preset accent offered in Settings → Appearance. Users can also pick any
/// custom color, which is stored as a raw hex outside this list.
struct LinkitAccent: Identifiable, Hashable {
    let name: String
    let hex: String

    var id: String { hex.uppercased() }
    var color: Color { Color(hexString: hex) ?? .orange }

    static let `default` = LinkitAccent(name: "Amber", hex: Preferences.defaultAccentHex)

    static let presets: [LinkitAccent] = [
        .default,
        LinkitAccent(name: "Sunset", hex: "#E2562B"),
        LinkitAccent(name: "Rose", hex: "#D6336C"),
        LinkitAccent(name: "Violet", hex: "#7C4DFF"),
        LinkitAccent(name: "Indigo", hex: "#3D5AFE"),
        LinkitAccent(name: "Ocean", hex: "#1E88E5"),
        LinkitAccent(name: "Teal", hex: "#00897B"),
        LinkitAccent(name: "Forest", hex: "#2E7D32"),
        LinkitAccent(name: "Graphite", hex: "#5A6370"),
    ]
}

extension Color {
    /// Parses `#RRGGBB` (the leading `#` is optional). Returns nil for anything else.
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// 6-digit `#RRGGBB` resolved in sRGB, or nil if the color can't be resolved.
    func toHexString() -> String? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
