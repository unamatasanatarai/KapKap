import CoreGraphics

/// Selection results from the region overlay, handled by `RecordingCoordinator`.
public protocol RegionSelectionOverlayDelegate: AnyObject {
    /// A drag finished. `rect` is in AppKit global points, already clamped to `screen`.
    func regionSelection(didSelect rect: CGRect, on screen: ScreenInfo)
    /// A new drag began (replacing the old selection) or the drag was too small to count.
    func regionSelectionDidClear()
}
