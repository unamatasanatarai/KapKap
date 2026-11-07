import CoreGraphics

/// Moving and resizing an existing section selection. Pure geometry in AppKit global points
/// (bottom-left origin), so "top" is `maxY`.
public enum SelectionEditing {
    /// Where on the selection a press landed.
    public enum Handle: Equatable, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case inside

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// How far (points) outside or inside an edge still grabs it.
    public static let grabTolerance: CGFloat = 6

    /// The handle under `point`, or nil when the press is outside the selection (a new drag).
    /// Edges and corners win over `inside` within `grabTolerance`.
    public static func handle(at point: CGPoint, in rect: CGRect,
                              tolerance: CGFloat = grabTolerance) -> Handle? {
        let grab = rect.insetBy(dx: -tolerance, dy: -tolerance)
        guard grab.contains(point) else { return nil }
        // Small selections: keep a grabbable middle so they can still be moved.
        let t = min(tolerance, rect.width / 4, rect.height / 4)
        let nearLeft = abs(point.x - rect.minX) <= max(t, 0) || point.x < rect.minX
        let nearRight = abs(point.x - rect.maxX) <= max(t, 0) || point.x > rect.maxX
        let nearBottom = abs(point.y - rect.minY) <= max(t, 0) || point.y < rect.minY
        let nearTop = abs(point.y - rect.maxY) <= max(t, 0) || point.y > rect.maxY
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return .inside
        }
    }

    /// `rect` with the grabbed handle dragged by `delta`, kept inside `bounds`. Dragging an edge past
    /// the opposite one flips the selection instead of collapsing it; it never gets smaller than `minSize`.
    public static func apply(_ handle: Handle, to rect: CGRect, delta: CGVector, bounds: CGRect,
                             minSize: CGFloat) -> CGRect {
        if handle == .inside {
            return moved(rect, by: delta, within: bounds)
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = clamp(rect.minX + delta.dx, bounds.minX, bounds.maxX) }
        if handle.movesRight { maxX = clamp(rect.maxX + delta.dx, bounds.minX, bounds.maxX) }
        if handle.movesBottom { minY = clamp(rect.minY + delta.dy, bounds.minY, bounds.maxY) }
        if handle.movesTop { maxY = clamp(rect.maxY + delta.dy, bounds.minY, bounds.maxY) }
        var result = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        // Enforce the minimum size by growing away from the dragged edge, within bounds.
        if result.width < minSize {
            let grow = minSize - result.width
            result.size.width = minSize
            if handle.movesLeft { result.origin.x -= grow }
            result.origin.x = clamp(result.origin.x, bounds.minX, bounds.maxX - minSize)
        }
        if result.height < minSize {
            let grow = minSize - result.height
            result.size.height = minSize
            if handle.movesBottom { result.origin.y -= grow }
            result.origin.y = clamp(result.origin.y, bounds.minY, bounds.maxY - minSize)
        }
        return result
    }

    /// `rect` moved by `delta`, sliding along the edges of `bounds` instead of leaving it.
    public static func moved(_ rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGRect {
        let x = clamp(rect.minX + delta.dx, bounds.minX, max(bounds.minX, bounds.maxX - rect.width))
        let y = clamp(rect.minY + delta.dy, bounds.minY, max(bounds.minY, bounds.maxY - rect.height))
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        return min(max(value, low), high)
    }
}
