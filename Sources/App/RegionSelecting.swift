import Foundation

/// What the coordinator needs from the region selection overlay, so tests can substitute a fake.
public protocol RegionSelecting: AnyObject {
    var selectionDelegate: RegionSelectionOverlayDelegate? { get set }
    /// Dims every screen and accepts a drag on any of them.
    func show()
    /// Removes the overlay windows (ordered out before they are released).
    func dismiss()
    /// Temporarily hides (true) or re-shows (false) the overlay without losing the selection, so a
    /// system prompt such as the microphone permission dialog is not covered.
    func setSuspended(_ suspended: Bool)
}
