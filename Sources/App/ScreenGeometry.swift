import CoreGraphics

/// Pure conversions between AppKit global coordinates and what ScreenCaptureKit needs.
///
///     AppKit global      points, origin at the bottom-left of the primary screen (NSEvent, NSScreen.frame)
///     SCK sourceRect     points, relative to the captured display, origin at its top-left
///     output size        pixels = points × scale, rounded down to even integers
public enum ScreenGeometry {
    /// The screen containing `p`. Matches `NSMouseInRect` for unflipped coordinates, so the mouse on the
    /// top row (y == maxY) belongs to the screen and the bottom edge belongs to the screen below.
    public static func screen(containing p: CGPoint, in screens: [ScreenInfo]) -> ScreenInfo? {
        return screens.first { s in
            p.x >= s.frame.minX && p.x < s.frame.maxX && p.y > s.frame.minY && p.y <= s.frame.maxY
        }
    }

    /// `r` limited to the screen's frame. A rect entirely off the screen collapses to an empty rect at
    /// the nearest point of the frame.
    public static func clamp(_ r: CGRect, to s: ScreenInfo) -> CGRect {
        let rect = r.standardized
        let clipped = rect.intersection(s.frame)
        if !clipped.isNull {
            return clipped
        }
        let x = min(max(rect.minX, s.frame.minX), s.frame.maxX)
        let y = min(max(rect.minY, s.frame.minY), s.frame.maxY)
        return CGRect(x: x, y: y, width: 0, height: 0)
    }

    /// AppKit global rect → display-relative, top-left origin points (SCK `sourceRect`). Uses the
    /// screen's own frame, never the primary screen's, so screens above or left of the primary work.
    public static func sourceRect(for r: CGRect, on s: ScreenInfo) -> CGRect {
        let rect = r.standardized
        return CGRect(
            x: rect.minX - s.frame.minX,
            y: s.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Output size in pixels, each dimension rounded down to an even integer and at least 2.
    public static func pixelSize(for r: CGRect, scale: CGFloat) -> CGSize {
        return CGSize(width: evenPixels(r.width * scale), height: evenPixels(r.height * scale))
    }

    /// The full capture region for a selection: clamped to the screen, snapped to whole pixels and sized
    /// so that `sourceRect × scale == pixelSize` exactly (no letterboxing from rounding).
    public static func captureRegion(for r: CGRect, on s: ScreenInfo) -> (sourceRect: CGRect, pixelSize: CGSize) {
        let scale = max(s.scale, 1)
        let local = sourceRect(for: clamp(r, to: s), on: s)
        let pixels = pixelSize(for: local, scale: scale)
        let width = pixels.width / scale
        let height = pixels.height / scale
        // Snap the origin to the pixel grid and keep the rect inside the display.
        let x = min(max(0, (local.minX * scale).rounded() / scale), max(0, s.frame.width - width))
        let y = min(max(0, (local.minY * scale).rounded() / scale), max(0, s.frame.height - height))
        return (CGRect(x: x, y: y, width: width, height: height), pixels)
    }

    private static func evenPixels(_ value: CGFloat) -> CGFloat {
        let whole = Int(value.rounded(.down))
        return CGFloat(max(2, whole - whole % 2))
    }
}
