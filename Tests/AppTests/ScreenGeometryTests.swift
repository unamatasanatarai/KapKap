import Cocoa
import CoreGraphics

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw RecordingTestFailure(description: message)
    }
}

/// `ScreenGeometry` over synthetic layouts, so multi-display cases run on the single-display dev Mac.
/// All frames are AppKit global points: origin at the bottom-left of the primary screen, y up.
public enum ScreenGeometryTests {
    /// Built-in Retina, primary: 1280×800 pt at 2×.
    private static let retina = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2)
    /// 1× external to the right, top-aligned with a taller frame.
    private static let rightOf = ScreenInfo(id: 2, frame: CGRect(x: 1280, y: -280, width: 1920, height: 1080), scale: 1)
    /// 2× external placed above the primary.
    private static let above = ScreenInfo(id: 3, frame: CGRect(x: -200, y: 800, width: 1512, height: 982), scale: 2)
    /// 1× external to the left (negative x origin).
    private static let leftOf = ScreenInfo(id: 4, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900), scale: 1)

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        runScreenLookupTests(testRunner)
        runSourceRectTests(testRunner)
        runClampAndPixelTests(testRunner)
        runOverlayInvalidationTests(testRunner)
    }

    /// Renders the overlay's layer tree for `selection` into a 1× bitmap; returns (width, height, RGBA).
    private static func renderOverlay(_ view: RegionSelectionView, selection: CGRect?) -> [UInt8] {
        view.selection = selection
        let w = Int(view.bounds.width), h = Int(view.bounds.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            view.layer!.render(in: ctx)
        }
        return bytes
    }

    private static func runOverlayInvalidationTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("RegionSelectionView dims exactly the area outside the selection") {
            let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
            let rect = CGRect(x: 50, y: 60, width: 120, height: 80)
            let dims = RegionSelectionView.dimRects(around: rect, in: bounds)
            let area = dims.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            try expect(area == 400 * 300 - 120 * 80, "dim covers bounds minus selection, got \(area)")
            for (i, a) in dims.enumerated() {
                try expect(!a.intersects(rect), "dim \(i) stays out of the selection")
                for b in dims[(i + 1)...] { try expect(!a.intersects(b), "dims do not overlap (no double dim)") }
            }
            try expect(RegionSelectionView.dimRects(around: nil, in: bounds)[0] == bounds, "no selection: all dim")
            let clipped = RegionSelectionView.dimRects(around: CGRect(x: -10, y: -10, width: 50, height: 50), in: bounds)
            let clippedArea = clipped.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            try expect(clippedArea == 400 * 300 - 40 * 40, "selection past the edge is clipped, got \(clippedArea)")
        }

        testRunner("RegionSelectionView layers render the dim, a clear inside, the border, handles and label") {
            let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 1)
            let rect = CGRect(x: 100, y: 100, width: 160, height: 100)
            let px = renderOverlay(view, selection: rect)
            func alpha(_ x: Int, _ y: Int) -> UInt8 { return px[((299 - y) * 400 + x) * 4 + 3] }   // rows top-down
            func red(_ x: Int, _ y: Int) -> UInt8 { return px[((299 - y) * 400 + x) * 4] }
            try expect(abs(Int(alpha(20, 280)) - 107) <= 2, "outside is dimmed 42%, alpha \(alpha(20, 280))")
            try expect(alpha(180, 170) == 0, "inside the selection is untouched")
            try expect(alpha(130, 200) > 200 && red(130, 200) > 200, "white dash on the top border")
            try expect(alpha(100, 100) == 255 && red(100, 100) > 200, "white handle on the corner")
            let snapshot = view.layerSnapshot
            try expect(snapshot.borders.count == 4 && snapshot.handles.count == 8, "border and handles visible")
            try expect(snapshot.labelText == "160 × 100" && snapshot.label != nil, "size label, got \(snapshot.labelText)")

            let none = renderOverlay(view, selection: nil)
            try expect(abs(Int(none[((299 - 170) * 400 + 180) * 4 + 3]) - 107) <= 2, "cleared: all dimmed again")
            try expect(view.layerSnapshot.borders.isEmpty && view.layerSnapshot.handles.isEmpty
                       && view.layerSnapshot.label == nil, "cleared: no decorations")
        }

        testRunner("RegionSelectionView moves layers without redrawing (a move keeps the label and border paths)") {
            let view = RegionSelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2)
            view.selection = CGRect(x: 50, y: 60, width: 120, height: 80)
            try expect(!view.needsDisplay, "a layer-hosting view never asks to draw")
            let before = view.layerSnapshot
            view.selection = CGRect(x: 70, y: 90, width: 120, height: 80)
            let after = view.layerSnapshot
            try expect(after.labelText == before.labelText && after.labelText == "240 × 160", "label text unchanged")
            try expect(zip(before.handles, after.handles).allSatisfy { $1.x - $0.x == 20 && $1.y - $0.y == 30 },
                       "handles follow the move")
            try expect(!view.needsDisplay, "still nothing to draw after a move")
        }
    }

    private static func runScreenLookupTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("ScreenGeometry finds the screen containing a point") {
            let screens = [retina, rightOf, above, leftOf]
            try expect(ScreenGeometry.screen(containing: CGPoint(x: 640, y: 400), in: screens) == retina, "primary")
            try expect(ScreenGeometry.screen(containing: CGPoint(x: 2000, y: -100), in: screens) == rightOf,
                       "right display below the primary's bottom")
            try expect(ScreenGeometry.screen(containing: CGPoint(x: 0, y: 1200), in: screens) == above, "above")
            try expect(ScreenGeometry.screen(containing: CGPoint(x: -700, y: 450), in: screens) == leftOf,
                       "negative origin")
            try expect(ScreenGeometry.screen(containing: CGPoint(x: 5000, y: 5000), in: screens) == nil,
                       "no screen far away")
        }

        testRunner("ScreenGeometry assigns shared edges like NSMouseInRect") {
            let screens = [retina, above]
            // The mouse's top row on the primary has y == maxY (800); it belongs to the primary.
            try expect(ScreenGeometry.screen(containing: CGPoint(x: 10, y: 800), in: screens) == retina,
                       "top edge belongs to the lower screen")
            try expect(ScreenGeometry.screen(containing: CGPoint(x: 1280, y: 10), in: [retina, rightOf]) == rightOf,
                       "x == maxX belongs to the screen on the right")
        }
    }

    private static func runSourceRectTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("ScreenGeometry source rect flips to top-left on a single Retina screen") {
            let r = CGRect(x: 100, y: 200, width: 300, height: 150)
            let source = ScreenGeometry.sourceRect(for: r, on: retina)
            try expect(source == CGRect(x: 100, y: 450, width: 300, height: 150), "got \(source)")
            let full = ScreenGeometry.sourceRect(for: retina.frame, on: retina)
            try expect(full == CGRect(x: 0, y: 0, width: 1280, height: 800), "whole screen, got \(full)")
        }

        testRunner("ScreenGeometry source rect is relative to a side-by-side screen with another scale") {
            // Top-left corner of the right display is (1280, 800) in global points.
            let r = CGRect(x: 1380, y: 600, width: 400, height: 100)
            let source = ScreenGeometry.sourceRect(for: r, on: rightOf)
            try expect(source == CGRect(x: 100, y: 100, width: 400, height: 100), "got \(source)")
            let pixels = ScreenGeometry.pixelSize(for: r, scale: rightOf.scale)
            try expect(pixels == CGSize(width: 400, height: 100), "1× pixels, got \(pixels)")
        }

        testRunner("ScreenGeometry source rect uses the screen's own frame above the primary") {
            // Flipping by the primary screen's height would give a negative y here.
            let r = CGRect(x: -100, y: 1600, width: 200, height: 100)
            let source = ScreenGeometry.sourceRect(for: r, on: above)
            try expect(source == CGRect(x: 100, y: 82, width: 200, height: 100), "got \(source)")
        }

        testRunner("ScreenGeometry source rect handles a negative-origin screen") {
            let r = CGRect(x: -1340, y: 700, width: 240, height: 100)
            let source = ScreenGeometry.sourceRect(for: r, on: leftOf)
            try expect(source == CGRect(x: 100, y: 100, width: 240, height: 100), "got \(source)")
        }

        testRunner("ScreenGeometry source rect normalizes a drag made right-to-left") {
            let reversed = CGRect(x: 400, y: 350, width: -300, height: -150)
            try expect(ScreenGeometry.sourceRect(for: reversed, on: retina)
                        == CGRect(x: 100, y: 450, width: 300, height: 150), "standardized first")
        }
    }

    private static func runClampAndPixelTests(_ testRunner: (String, () throws -> Void) -> Void) {
        testRunner("ScreenGeometry clamps a rect that crosses screen edges") {
            let crossing = CGRect(x: 1200, y: 700, width: 300, height: 300)
            let clamped = ScreenGeometry.clamp(crossing, to: retina)
            try expect(clamped == CGRect(x: 1200, y: 700, width: 80, height: 100), "got \(clamped)")

            let intoNegative = CGRect(x: -50, y: -20, width: 100, height: 100)
            try expect(ScreenGeometry.clamp(intoNegative, to: retina) == CGRect(x: 0, y: 0, width: 50, height: 80),
                       "clamped at the bottom-left corner")

            let offScreen = ScreenGeometry.clamp(CGRect(x: 2000, y: 100, width: 50, height: 50), to: retina)
            try expect(offScreen.width == 0 && offScreen.height == 0 && offScreen.minX == 1280,
                       "off-screen collapses to the nearest edge, got \(offScreen)")
        }

        testRunner("ScreenGeometry rounds odd pixel sizes down to even") {
            try expect(ScreenGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 2)
                        == CGSize(width: 2560, height: 1600), "full Retina screen")
            try expect(ScreenGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 333, height: 201), scale: 1)
                        == CGSize(width: 332, height: 200), "odd 1× sizes")
            try expect(ScreenGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 100.75, height: 50.25), scale: 2)
                        == CGSize(width: 200, height: 100), "fractional points at 2×")
            try expect(ScreenGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 0.4, height: 0), scale: 1)
                        == CGSize(width: 2, height: 2), "minimum 2×2")
        }

        testRunner("ScreenGeometry capture region matches the pixel size exactly") {
            // Odd-pixel drag on a 1× screen: 333×201 pt → 332×200 px, so the source rect shrinks to match.
            // Local origin (100.4, 99.4) snaps to (100, 99).
            let r = CGRect(x: 1380.4, y: 499.6, width: 333, height: 201)
            let region = ScreenGeometry.captureRegion(for: r, on: rightOf)
            try expect(region.pixelSize == CGSize(width: 332, height: 200), "got \(region.pixelSize)")
            try expect(region.sourceRect.size == CGSize(width: 332, height: 200), "got \(region.sourceRect)")
            try expect(region.sourceRect.origin == CGPoint(x: 100, y: 99), "snapped to whole pixels, got \(region.sourceRect)")

            // A drag past the screen edge is clamped before conversion.
            let edge = ScreenGeometry.captureRegion(for: CGRect(x: 1000, y: -50, width: 500, height: 150), on: retina)
            try expect(edge.sourceRect == CGRect(x: 1000, y: 700, width: 280, height: 100), "got \(edge.sourceRect)")
            try expect(edge.pixelSize == CGSize(width: 560, height: 200), "got \(edge.pixelSize)")
        }
    }
}
