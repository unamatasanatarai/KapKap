import Cocoa
import QuartzCore

/// What the coordinator needs from the outline shown around a section while it records.
public protocol RecordingOutlinePresenting: AnyObject {
    /// Outlines `rect` (AppKit global points: the exact area being captured).
    func show(around rect: CGRect)
    func hide()
}

/// A living frame around the section being recorded: a 1-pixel, sharp-cornered line in the app icon's
/// blues with white highlight bands, tilted at 70°, scrolling continuously along the frame while the
/// line gently breathes. The line sits entirely outside the captured area (CGDisplayStream records
/// every window on screen, ours included), and ignores the mouse. It animates regardless of Reduce
/// Motion, by design.
///
/// Performance: each edge is a one-pixel layer. Along a straight edge the tilted band
/// pattern is just a 1-D gradient with a fixed wavelength, so each edge holds a tiny unrotated gradient
/// layer (edge length + one wavelength, one pixel thick) that slides by one wavelength per cycle. All
/// edges use the same global phase, so the bands meet exactly at the corners. Everything lives in one
/// transparent window (four separate windows measured costlier), and the shimmer is stepped 10 times a
/// second from a timer, because WindowServer's cost is per composited frame (see `stepsPerSecond`).
public final class RecordingOutlineWindow: NSObject, RecordingOutlinePresenting {
    /// Gap between the captured area and the inner edge of the line, in points.
    public static let gap: CGFloat = 2
    /// Angle of the gradient bands (degrees from the horizontal).
    public static let bandAngle: CGFloat = 70
    /// One full scroll of the gradient pattern (one wavelength): 240 pt in 3.6 s ≈ 67 pt/s, so each of
    /// the 10 steps a second moves the bands ≈ 6.7 pt.
    public static let scrollPeriod: CFTimeInterval = 3.6
    public static let breathePeriod: CFTimeInterval = 1.6
    /// Width of one gradient period along its axis, in points.
    static let bandWavelength: CGFloat = 240

    /// The app icon's blues, deepened for contrast: deep blue → icon blue → pale blue → white
    /// highlight → pale blue → icon blue (then back to deep blue at the start of the next period).
    static let bandColors: [CGColor] = [
        CGColor(srgbRed: 0x3d / 255.0, green: 0x6b / 255.0, blue: 0xf0 / 255.0, alpha: 1),
        CGColor(srgbRed: 0x8e / 255.0, green: 0xb0 / 255.0, blue: 0xf7 / 255.0, alpha: 1),
        CGColor(srgbRed: 0xdc / 255.0, green: 0xe8 / 255.0, blue: 0xff / 255.0, alpha: 1),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        CGColor(srgbRed: 0xdc / 255.0, green: 0xe8 / 255.0, blue: 0xff / 255.0, alpha: 1),
        CGColor(srgbRed: 0x8e / 255.0, green: 0xb0 / 255.0, blue: 0xf7 / 255.0, alpha: 1)
    ]

    /// One edge: a one-pixel clip layer holding a short 1-D gradient that slides along it.
    private final class Edge {
        let clip = CALayer()
        let stripes = CAGradientLayer()

        init() {
            clip.masksToBounds = true
            clip.addSublayer(stripes)
        }
    }

    /// One transparent window spanning the outline; only the four one-pixel edge layers have content,
    /// so each frame only those strips change. (One surface: four separate windows measured worse.)
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view = NSView()
        view.wantsLayer = true
        view.layer = rootLayer
        edges.forEach { rootLayer.addSublayer($0.clip) }
        window.contentView = view
        return window
    }()
    private let rootLayer = CALayer()
    private let edges: [Edge] = (0..<4).map { _ in Edge() }
    private var animating = false
    /// Per edge: how far the gradient slides along the edge in one cycle (± one wavelength).
    private var shifts: [CGFloat] = []

    public override init() {
        super.init()
    }

    // MARK: - Geometry

    /// One physical pixel in points on a display with `scale`.
    static func lineWidth(scale: CGFloat) -> CGFloat {
        return 1 / max(scale, 1)
    }

    /// The outer bounds of the outline around `rect`: `gap`, then the 1-pixel line; nothing inside `rect`.
    public static func frame(around rect: CGRect, scale: CGFloat = 2) -> CGRect {
        let inset = gap + lineWidth(scale: scale)
        return rect.insetBy(dx: -inset, dy: -inset)
    }

    /// The four one-pixel edge rects (top, bottom, left, right) of the outline's outer frame. They tile
    /// the ring exactly, without overlap, so corners are square.
    static func edgeRects(around rect: CGRect, scale: CGFloat) -> [CGRect] {
        let outer = frame(around: rect, scale: scale)
        let px = lineWidth(scale: scale)
        return [
            CGRect(x: outer.minX, y: outer.maxY - px, width: outer.width, height: px),
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: px),
            CGRect(x: outer.minX, y: outer.minY + px, width: px, height: outer.height - 2 * px),
            CGRect(x: outer.maxX - px, y: outer.minY + px, width: px, height: outer.height - 2 * px)
        ]
    }

    /// The band pattern's phase (in periods) at a point of the outline: constant along lines at
    /// `bandAngle`, growing by 1 every `bandWavelength` along the gradient axis.
    static func phase(at point: CGPoint) -> CGFloat {
        let a = axisAngle
        return (point.x * cos(a) + point.y * sin(a)) / bandWavelength
    }

    /// The 1-D gradient for one straight edge starting at `origin` (outline coordinates) running along
    /// unit `direction` for `length` points. Returns where the gradient layer starts and ends along the
    /// edge (it overhangs both ends so it still covers the edge after sliding), whether its colours run
    /// against the edge direction, how many periods it holds, and how far it slides per cycle.
    struct EdgeGradient: Equatable {
        let start: CGFloat
        let end: CGFloat
        let reversed: Bool
        let periods: Int
        let shift: CGFloat
    }

    static func edgeGradient(origin: CGPoint, direction: CGVector, length: CGFloat) -> EdgeGradient {
        let a = axisAngle
        let rate = (direction.dx * cos(a) + direction.dy * sin(a)) / bandWavelength   // periods per point
        let wavelength = 1 / abs(rate)
        let phase0 = phase(at: origin)
        if rate > 0 {
            // Phase grows along the edge: start one wavelength before it, on a whole period.
            let start = (floor(phase0) - 1 - phase0) / rate
            let periods = Int(ceil((length - start) / wavelength))
            return EdgeGradient(start: start, end: start + CGFloat(periods) * wavelength, reversed: false,
                                periods: periods, shift: wavelength)
        }
        // Phase falls along the edge: anchor a whole period one wavelength past the far end.
        let phaseBeyond = phase0 + rate * (length + wavelength)
        let end = (floor(phaseBeyond) - phase0) / rate
        let periods = Int(ceil(end / wavelength))
        return EdgeGradient(start: end - CGFloat(periods) * wavelength, end: end, reversed: true,
                            periods: periods, shift: -wavelength)
    }

    /// The band colours repeated `periods` times, with stops spaced so every period is identical
    /// (each period ends where the next begins), which makes a one-period scroll seamless.
    static func repeatedBands(periods: Int) -> (colors: [CGColor], locations: [NSNumber]) {
        let perPeriod = bandColors.count
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        for p in 0..<periods {
            for (i, color) in bandColors.enumerated() {
                colors.append(color)
                locations.append(NSNumber(value: (Double(p) + Double(i) / Double(perPeriod)) / Double(periods)))
            }
        }
        // Close the last period with its first colour so it matches the start of a period.
        colors.append(bandColors[0])
        locations.append(1)
        return (colors, locations)
    }

    /// Rotation of the gradient axis: bands run perpendicular to it, so a 70° band means a −20° axis.
    static var axisAngle: CGFloat {
        return (bandAngle - 90) * .pi / 180
    }

    // MARK: - RecordingOutlinePresenting

    public func show(around rect: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let outer = Self.frame(around: rect, scale: scale)

        window.setFrame(outer, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.contentsScale = scale
        rootLayer.frame = CGRect(origin: .zero, size: outer.size)
        shifts = []
        for (edge, edgeRect) in zip(edges, Self.edgeRects(around: rect, scale: scale)) {
            let horizontal = edgeRect.width >= edgeRect.height
            let origin = CGPoint(x: edgeRect.minX - outer.minX, y: edgeRect.minY - outer.minY)
            let direction = horizontal ? CGVector(dx: 1, dy: 0) : CGVector(dx: 0, dy: 1)
            let length = horizontal ? edgeRect.width : edgeRect.height
            let gradient = Self.edgeGradient(origin: origin, direction: direction, length: length)
            let bands = Self.repeatedBands(periods: gradient.periods)

            edge.clip.contentsScale = scale
            edge.clip.frame = CGRect(origin: origin, size: edgeRect.size)
            edge.stripes.contentsScale = scale
            edge.stripes.colors = bands.colors
            edge.stripes.locations = bands.locations
            if horizontal {
                edge.stripes.frame = CGRect(x: gradient.start, y: 0, width: gradient.end - gradient.start,
                                            height: edgeRect.height)
                edge.stripes.startPoint = CGPoint(x: gradient.reversed ? 1 : 0, y: 0.5)
                edge.stripes.endPoint = CGPoint(x: gradient.reversed ? 0 : 1, y: 0.5)
            } else {
                edge.stripes.frame = CGRect(x: 0, y: gradient.start, width: edgeRect.width,
                                            height: gradient.end - gradient.start)
                edge.stripes.startPoint = CGPoint(x: 0.5, y: gradient.reversed ? 1 : 0)
                edge.stripes.endPoint = CGPoint(x: 0.5, y: gradient.reversed ? 0 : 1)
            }
            shifts.append(gradient.shift)
        }
        CATransaction.commit()
        window.orderFrontRegardless()
        startAnimating()
    }

    public func hide() {
        stopAnimating()
        window.orderOut(nil)
    }

    /// Starting positions of the gradient layers; each step offsets them by a fraction of `shifts`.
    private var basePositions: [CGPoint] = []
    private var stepTimer: DispatchSourceTimer?
    private var animationStart: CFTimeInterval = 0

    /// The shimmer is stepped from a timer at `stepsPerSecond` instead of running as a continuous Core
    /// Animation animation: WindowServer's cost is per composited frame of the window, so fewer frames is
    /// what saves CPU (measured: a CA animation runs at the display rate, and preferredFrameRateRange on
    /// macOS 12 made it costlier, not cheaper).
    static let stepsPerSecond: Double = 10

    /// The scroll fraction (0..<1 of one wavelength) and line opacity at `elapsed` seconds.
    static func animationState(at elapsed: CFTimeInterval) -> (scroll: CGFloat, opacity: Float) {
        let scroll = CGFloat((elapsed / scrollPeriod).truncatingRemainder(dividingBy: 1))
        // Breathes between 1.0 and 0.7 once per breathePeriod, starting bright.
        let opacity = Float(0.85 + 0.15 * cos(2 * .pi * elapsed / breathePeriod))
        return (scroll, opacity)
    }

    private var occlusionObserver: NSObjectProtocol?

    private func startAnimating() {
        stopAnimating()
        basePositions = edges.map { $0.stripes.position }
        animationStart = CACurrentMediaTime()
        animating = true
        startTimer()
        // Stop stepping while the outline cannot be seen (screen locked, display asleep, covered, other
        // Space); resume in phase when it is visible again.
        if occlusionObserver == nil {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                self?.occlusionChanged()
            }
        }
    }

    private func occlusionChanged() {
        guard animating else { return }
        if window.occlusionState.contains(.visible) {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        guard stepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = 1 / Self.stepsPerSecond
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.step() }
        timer.resume()
        stepTimer = timer
    }

    private func stopTimer() {
        stepTimer?.cancel()
        stepTimer = nil
    }

    private func step() {
        let state = Self.animationState(at: CACurrentMediaTime() - animationStart)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, edge) in edges.enumerated() {
            // Every edge slides by the same fraction of one period of the shared pattern, so corners
            // stay aligned and the loop is seamless.
            let base = basePositions[index]
            let offset = shifts[index] * state.scroll
            let horizontal = edge.clip.bounds.width >= edge.clip.bounds.height
            edge.stripes.position = horizontal ? CGPoint(x: base.x + offset, y: base.y)
                                               : CGPoint(x: base.x, y: base.y + offset)
            edge.clip.opacity = state.opacity
        }
        CATransaction.commit()
    }

    private func stopAnimating() {
        guard animating else { return }
        stopTimer()
        animating = false
    }

    deinit {
        stopTimer()
        if let observer = occlusionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Whether the outline is currently stepping (for tests).
    var isStepping: Bool {
        return stepTimer != nil
    }

    /// Test hook: what an occlusion change does.
    func simulateOcclusion(visible: Bool) {
        guard animating else { return }
        visible ? startTimer() : stopTimer()
    }

    /// Whether the outline is currently animating (for tests).
    var isAnimating: Bool {
        return animating
    }
}
