import Foundation

public protocol StatusBarControllerDelegate: AnyObject {
    /// "Record Screen" was chosen from the menu, or the idle status item was left-clicked.
    func recordScreenRequested()
    /// The status item was clicked while in recording mode.
    func stopRequested()
}
