import Foundation

/// Actions from the record control panel, handled by `RecordingCoordinator`.
public protocol RecordControlPanelDelegate: AnyObject {
    /// A toggle or the Fullscreen / Section choice changed.
    func recordControl(didChangeOptions options: RecordingOptions)
    /// ● Record was clicked.
    func recordControlDidRequestRecord()
    /// ✕ was clicked.
    func recordControlDidCancel()
    /// Esc was pressed while the panel was key.
    func recordControlDidPressEscape()
}
