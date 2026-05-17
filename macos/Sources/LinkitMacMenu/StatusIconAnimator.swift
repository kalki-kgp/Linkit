import AppKit

enum LinkitStatusIconState: Equatable {
    case disconnected
    case connected
    case pairing
    case transferring(direction: LinkitTransferDirection)
    case success
    case error

    var isAnimated: Bool {
        switch self {
        case .pairing, .transferring, .success, .error:
            return true
        case .connected, .disconnected:
            return false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .disconnected: return "Linkit not connected"
        case .connected: return "Linkit connected"
        case .pairing: return "Linkit pairing"
        case .transferring: return "Linkit transferring"
        case .success: return "Linkit complete"
        case .error: return "Linkit error"
        }
    }
}

enum LinkitTransferDirection: Equatable {
    case androidToMac
    case macToAndroid
}

final class StatusIconAnimator {
    private weak var button: NSStatusBarButton?
    private var timer: DispatchSourceTimer?
    private var frame: Int = 0
    private var state: LinkitStatusIconState = .disconnected
    private let renderer = StatusIconRenderer()

    init(button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Linkit"
        setState(.disconnected)
    }

    deinit {
        timer?.cancel()
    }

    func setState(_ next: LinkitStatusIconState, tooltip: String? = nil) {
        guard state != next || tooltip != nil else { return }
        state = next
        frame = 0
        button?.toolTip = tooltip ?? next.accessibilityLabel
        renderCurrentFrame()
        next.isAnimated ? startTimer() : stopTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(67), repeating: .milliseconds(67))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.frame += 1
            self.renderCurrentFrame()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func renderCurrentFrame() {
        guard let button else { return }
        let image = renderer.image(for: state, frame: frame)
        image.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(state.accessibilityLabel)
    }
}

private final class StatusIconRenderer {
    private let size = NSSize(width: 34, height: 18)

    func image(for state: LinkitStatusIconState, frame: Int) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let color = NSColor.black
        drawDevices(color: color)

        switch state {
        case .connected:
            drawChain(color: color, alpha: 1)
        case .disconnected:
            drawBrokenChain(color: color)
        case .pairing:
            let phase = smoothPingPong(frame, cycle: 54)
            drawPairingChain(color: color, progress: phase)
        case .transferring(let direction):
            drawChain(color: color, alpha: 0.9)
            drawMovingFiles(color: color, frame: frame, direction: direction)
        case .success:
            drawChain(color: color, alpha: 1)
            drawTick(color: color, progress: min(1, CGFloat(frame) / 12))
        case .error:
            drawBrokenChain(color: color)
        }
        return image
    }

    private func drawDevices(color: NSColor) {
        color.setStroke()
        color.setFill()

        let phone = roundedRect(NSRect(x: 1.6, y: 2.7, width: 6.8, height: 12.6), radius: 1.25)
        phone.lineWidth = 1.15
        phone.stroke()

        let speaker = NSBezierPath()
        speaker.lineWidth = 0.75
        speaker.lineCapStyle = .round
        speaker.move(to: NSPoint(x: 3.25, y: 13.9))
        speaker.line(to: NSPoint(x: 6.35, y: 13.9))
        speaker.stroke()

        let screen = roundedRect(NSRect(x: 21.4, y: 5.35, width: 10.6, height: 8.8), radius: 0.4)
        screen.lineWidth = 1.15
        screen.stroke()

        let base = NSBezierPath()
        base.lineWidth = 1.25
        base.lineCapStyle = .round
        base.move(to: NSPoint(x: 20.0, y: 3.25))
        base.line(to: NSPoint(x: 33.0, y: 3.25))
        base.stroke()

        let notch = NSBezierPath()
        notch.lineWidth = 0.65
        notch.lineCapStyle = .round
        notch.move(to: NSPoint(x: 25.2, y: 4.2))
        notch.line(to: NSPoint(x: 27.6, y: 4.2))
        notch.stroke()
    }

    private func drawChain(color: NSColor, alpha: CGFloat) {
        color.withAlphaComponent(alpha).setStroke()
        let outer = roundedRect(NSRect(x: 7.7, y: 6.75, width: 17.9, height: 5.5), radius: 2.75)
        outer.lineWidth = 1.45
        outer.stroke()
    }

    private func drawPairingChain(color: NSColor, progress: CGFloat) {
        let clamped = max(0, min(1, progress))
        color.withAlphaComponent(0.35 + 0.65 * clamped).setStroke()

        let left = NSBezierPath()
        left.lineWidth = 1.45
        left.lineCapStyle = .round
        left.move(to: NSPoint(x: 8.4, y: 9.5))
        left.line(to: NSPoint(x: 8.4 + 6.8 * clamped, y: 9.5))
        left.stroke()

        let right = NSBezierPath()
        right.lineWidth = 1.45
        right.lineCapStyle = .round
        right.move(to: NSPoint(x: 24.9, y: 9.5))
        right.line(to: NSPoint(x: 24.9 - 6.8 * clamped, y: 9.5))
        right.stroke()

        if clamped > 0.72 {
            drawChain(color: color, alpha: (clamped - 0.72) / 0.28)
        }
    }

    private func drawBrokenChain(color: NSColor) {
        color.setStroke()

        let left = NSBezierPath()
        left.lineWidth = 1.45
        left.lineCapStyle = .round
        left.move(to: NSPoint(x: 7.9, y: 9.5))
        left.curve(
            to: NSPoint(x: 14.1, y: 9.5),
            controlPoint1: NSPoint(x: 8.8, y: 12.0),
            controlPoint2: NSPoint(x: 12.8, y: 12.0)
        )
        left.stroke()

        let right = NSBezierPath()
        right.lineWidth = 1.45
        right.lineCapStyle = .round
        right.move(to: NSPoint(x: 19.0, y: 9.5))
        right.curve(
            to: NSPoint(x: 25.2, y: 9.5),
            controlPoint1: NSPoint(x: 20.3, y: 7.0),
            controlPoint2: NSPoint(x: 24.2, y: 7.0)
        )
        right.stroke()

        let crack = NSBezierPath()
        crack.lineWidth = 0.85
        crack.lineCapStyle = .round
        crack.move(to: NSPoint(x: 15.4, y: 11.65))
        crack.line(to: NSPoint(x: 16.5, y: 9.65))
        crack.line(to: NSPoint(x: 15.6, y: 7.75))
        crack.stroke()
    }

    private func drawMovingFiles(color: NSColor, frame: Int, direction: LinkitTransferDirection) {
        color.setFill()
        let cycle = 42
        for offset in [0, 14, 28] {
            let raw = CGFloat((frame + offset) % cycle) / CGFloat(cycle)
            let progress = direction == .androidToMac ? raw : 1 - raw
            let x = 9.3 + 13.2 * progress
            let bob = sin((raw * 2 * .pi)) * 0.8
            let rect = NSRect(x: x, y: 8.55 + bob, width: 1.55, height: 1.85)
            roundedRect(rect, radius: 0.25).fill()
        }
    }

    private func drawTick(color: NSColor, progress: CGFloat) {
        let p = max(0, min(1, progress))
        color.setStroke()
        let tick = NSBezierPath()
        tick.lineWidth = 1.25
        tick.lineCapStyle = .round
        tick.lineJoinStyle = .round

        let a = NSPoint(x: 13.6, y: 9.2)
        let b = NSPoint(x: 15.8, y: 7.2)
        let c = NSPoint(x: 20.0, y: 11.7)

        tick.move(to: a)
        if p < 0.45 {
            tick.line(to: interpolate(a, b, p / 0.45))
        } else {
            tick.line(to: b)
            tick.line(to: interpolate(b, c, (p - 0.45) / 0.55))
        }
        tick.stroke()
    }

    private func smoothPingPong(_ frame: Int, cycle: Int) -> CGFloat {
        let raw = CGFloat(frame % cycle) / CGFloat(cycle)
        let triangle = raw < 0.5 ? raw * 2 : (1 - raw) * 2
        return triangle * triangle * (3 - 2 * triangle)
    }

    private func interpolate(_ start: NSPoint, _ end: NSPoint, _ progress: CGFloat) -> NSPoint {
        NSPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }

    private func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
}
