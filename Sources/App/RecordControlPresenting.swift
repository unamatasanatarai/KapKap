import Foundation

/// What the coordinator needs from the record control panel, so tests can substitute a fake.
public protocol RecordControlPresenting: AnyObject {
    var controlDelegate: RecordControlPanelDelegate? { get set }
    /// Shows the panel on the display under the mouse with `options` applied.
    func show(options: RecordingOptions)
    /// Hides the panel without releasing it.
    func dismiss()
    /// Updates the Fullscreen / Section choice without notifying the delegate.
    func setArea(_ area: RecordingOptions.Area)
    func setRecordEnabled(_ enabled: Bool)
    /// Updates the Microphone switch without notifying the delegate (used when access is denied).
    func setMicrophone(_ on: Bool)
    /// Drops the panel below system prompts (true) or restores its level above the overlay (false).
    func setSuspended(_ suspended: Bool)
}
