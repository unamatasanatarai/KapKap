import Cocoa

/// One screen of the region overlay: a 42% dim outside the selection, a dashed border, the selection's
/// pixel size, and move/resize handles. No text hints: the UI is icons only. Mouse events are forwarded
/// in AppKit global points.
///
/// Performance: nothing is drawn with Core Graphics per mouse event. The view hosts a tree of small
/// layers that a drag only moves and resizes:
/// - the dim is four solid layers around the selection (pure compositing, no rasterization);
/// - the dashed border is four one-edge shape layers, each just a thin strip;
/// - the handles are eight 7 pt layers; the size label is a pill whose text re-renders only when the
///   size changes (never while moving).
/// The previous drawRect overlay repainted 1–6 ms of Retina pixels on the main thread per event.
public final class RegionSelectionView: NSView {

    /// The selection in this view's coordinates, or nil.
    public var selection: CGRect? {
        didSet {
            guard selection != oldValue else { return }
            updateLayers()
        }
    }

    public static let dimAlpha: CGFloat = 0.42
    static let borderWidth: CGFloat = 1.5
    static let dashPattern: [NSNumber] = [6, 4]
    static let handleSize: CGFloat = 7

    private let dimLayers: [CALayer] = (0..<4).map { _ in CALayer() }
    private let borderLayers: [CAShapeLayer] = (0..<4).map { _ in CAShapeLayer() }
    private let handleLayers: [CALayer] = (0..<8).map { _ in CALayer() }
    private let labelLayer = CALayer()
    private let labelTextLayer = CATextLayer()
    private var labelString = ""
    /// Border edge lengths last given a path, so a pure move never rebuilds a path.
    private var borderLengths: [CGFloat] = [-1, -1, -1, -1]

    /// A move or resize of the selection is in progress (closed-hand cursor while moving).
    public var isDraggingSelection = false

    public var onMouseDown: ((CGPoint) -> Void)?
    public var onMouseDragged: ((CGPoint) -> Void)?
    public var onMouseUp: ((CGPoint) -> Void)?

    private let scale: CGFloat

    public init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        setUpLayers()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isOpaque: Bool {
        return false
    }

    // The overlay window never becomes key (the panel keeps Esc), so the first click must count.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // MARK: - Cursor

    /// The cursor for a point in this view: hand inside the selection, resize arrows on its edges,
    /// crosshair elsewhere (and on corners, which have no public diagonal cursor).
    public static func cursor(for handle: SelectionEditing.Handle?, dragging: Bool) -> NSCursor {
        switch handle {
        case .inside?: return dragging ? .closedHand : .openHand
        case .left?, .right?: return .resizeLeftRight
        case .top?, .bottom?: return .resizeUpDown
        default: return .crosshair
        }
    }

    private var handleUnderMouse: SelectionEditing.Handle?

    private func updateCursor(at event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isDraggingSelection {
            handleUnderMouse = selection.flatMap { SelectionEditing.handle(at: point, in: $0) }
        }
        Self.cursor(for: handleUnderMouse, dragging: isDraggingSelection).set()
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    public override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: event)
    }

    public override func mouseEntered(with event: NSEvent) {
        updateCursor(at: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        updateCursor(at: event)
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        onMouseDown?(globalPoint(event))
        updateCursor(at: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(globalPoint(event))
        updateCursor(at: event)
    }

    public override func mouseUp(with event: NSEvent) {
        onMouseUp?(globalPoint(event))
        updateCursor(at: event)
    }

    private func globalPoint(_ event: NSEvent) -> CGPoint {
        guard let window = window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    // MARK: - Layers

    /// No implicit animations anywhere: every change lands in the next frame, as a drag needs.
    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "hidden": NSNull(),
        "contents": NSNull(), "string": NSNull(), "opacity": NSNull()
    ]

    private func setUpLayers() {
        let root = CALayer()
        root.actions = Self.noActions
        root.contentsScale = scale
        // A layer-hosting view: AppKit never asks it to draw.
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        let dim = NSColor.black.withAlphaComponent(Self.dimAlpha).cgColor
        for layer in dimLayers {
            layer.actions = Self.noActions
            layer.backgroundColor = dim
            root.addSublayer(layer)
        }
        for layer in borderLayers {
            layer.actions = Self.noActions
            layer.contentsScale = scale
            layer.fillColor = nil
            layer.strokeColor = NSColor.white.cgColor
            layer.lineWidth = Self.borderWidth
            layer.lineDashPattern = Self.dashPattern
            layer.isHidden = true
            root.addSublayer(layer)
        }
        for layer in handleLayers {
            layer.actions = Self.noActions
            layer.contentsScale = scale
            layer.backgroundColor = NSColor.white.cgColor
            layer.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor
            layer.borderWidth = 1
            layer.bounds = CGRect(x: 0, y: 0, width: Self.handleSize, height: Self.handleSize)
            layer.isHidden = true
            root.addSublayer(layer)
        }
        labelLayer.actions = Self.noActions
        labelLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        labelLayer.cornerRadius = 4
        labelLayer.isHidden = true
        labelTextLayer.actions = Self.noActions
        labelTextLayer.contentsScale = scale
        labelTextLayer.alignmentMode = .center
        labelLayer.addSublayer(labelTextLayer)
        root.addSublayer(labelLayer)
        updateLayers()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayers()
    }

    /// The four dim rects around `selection` (top, bottom, left, right), or the whole view without one.
    static func dimRects(around selection: CGRect?, in bounds: CGRect) -> [CGRect] {
        guard let rect = selection?.intersection(bounds), !rect.isNull, rect.width > 0, rect.height > 0 else {
            return [bounds, .zero, .zero, .zero]
        }
        return [
            CGRect(x: bounds.minX, y: rect.maxY, width: bounds.width, height: bounds.maxY - rect.maxY),
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: rect.minY - bounds.minY),
            CGRect(x: bounds.minX, y: rect.minY, width: rect.minX - bounds.minX, height: rect.height),
            CGRect(x: rect.maxX, y: rect.minY, width: bounds.maxX - rect.maxX, height: rect.height)
        ]
    }

    /// Centres of the eight handles: corners and edge midpoints.
    static func handleCenters(for rect: CGRect) -> [CGPoint] {
        return [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let visible = selection.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        for (layer, rect) in zip(dimLayers, Self.dimRects(around: visible, in: bounds)) {
            layer.frame = rect
        }
        guard let rect = visible else {
            (borderLayers as [CALayer] + handleLayers + [labelLayer]).forEach { $0.isHidden = true }
            return
        }
        updateBorder(around: rect)
        for (layer, center) in zip(handleLayers, Self.handleCenters(for: rect)) {
            layer.position = center
            layer.isHidden = false
        }
        updateLabel(for: rect)
    }

    /// 1.5 pt dashed white border just outside the selection, so the inside is exactly what is recorded.
    /// Each edge is a strip-sized shape layer; its path changes only when that edge's length does.
    private func updateBorder(around rect: CGRect) {
        let w = Self.borderWidth
        let outer = rect.insetBy(dx: -w, dy: -w)
        let strips = [
            CGRect(x: outer.minX, y: rect.maxY, width: outer.width, height: w),     // top
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: w),    // bottom
            CGRect(x: outer.minX, y: rect.minY, width: w, height: rect.height),     // left
            CGRect(x: rect.maxX, y: rect.minY, width: w, height: rect.height)       // right
        ]
        for (index, (layer, strip)) in zip(borderLayers, strips).enumerated() {
            let horizontal = index < 2
            let length = horizontal ? strip.width : strip.height
            layer.frame = strip
            if length != borderLengths[index] {
                let path = CGMutablePath()
                if horizontal {
                    path.move(to: CGPoint(x: 0, y: w / 2))
                    path.addLine(to: CGPoint(x: length, y: w / 2))
                } else {
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: length))
                }
                layer.path = path
                borderLengths[index] = length
            }
            layer.isHidden = false
        }
    }

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.white
    ]

    private static func labelText(for rect: CGRect, scale: CGFloat) -> NSAttributedString {
        let pixels = ScreenGeometry.pixelSize(for: rect, scale: scale)
        return NSAttributedString(string: "\(Int(pixels.width)) × \(Int(pixels.height))", attributes: labelAttributes)
    }

    /// Where the "W × H" pill goes: under the selection's bottom-right corner (inside when there is no room).
    static func labelRect(for rect: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect {
        return labelRect(for: rect, textSize: labelText(for: rect, scale: scale).size(), in: bounds)
    }

    private static func labelRect(for rect: CGRect, textSize: CGSize, in bounds: CGRect) -> CGRect {
        let size = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)
        var origin = CGPoint(x: rect.maxX - 4 - size.width, y: rect.minY - 4 - size.height)
        if origin.y < bounds.minY + 4 {
            origin.y = rect.minY + 4
        }
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - 4 - size.width))
        return CGRect(origin: origin, size: size)
    }

    /// "W × H" in output pixels. The text layer re-renders only when the text changes.
    private func updateLabel(for rect: CGRect) {
        let text = Self.labelText(for: rect, scale: scale)
        let textSize = text.size()
        let pill = Self.labelRect(for: rect, textSize: textSize, in: bounds)
        if text.string != labelString {
            labelString = text.string
            labelTextLayer.string = text
            let height = ceil(textSize.height)
            labelTextLayer.frame = CGRect(x: 0, y: (pill.height - height) / 2, width: pill.width, height: height)
        }
        labelLayer.frame = pill
        labelLayer.isHidden = false
    }

    // MARK: - Testing

    /// The current layer state, for tests: dim rects, visible border strips, handle centres, label frame.
    var layerSnapshot: (dims: [CGRect], borders: [CGRect], handles: [CGPoint], label: CGRect?, labelText: String) {
        return (dimLayers.map { $0.frame },
                borderLayers.filter { !$0.isHidden }.map { $0.frame },
                handleLayers.filter { !$0.isHidden }.map { $0.position },
                labelLayer.isHidden ? nil : labelLayer.frame,
                labelString)
    }
}
