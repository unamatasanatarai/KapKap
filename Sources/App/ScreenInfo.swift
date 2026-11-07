import Cocoa

/// A display as plain values, so geometry can be tested without real screens.
public struct ScreenInfo: Equatable {
    public let id: CGDirectDisplayID
    /// The screen's frame in AppKit global points (origin at the bottom-left of the primary screen).
    public let frame: CGRect
    /// Pixels per point (`backingScaleFactor`).
    public let scale: CGFloat

    public init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }

    /// Reads `NSScreenNumber`, which is the `CGDirectDisplayID` that ScreenCaptureKit matches on.
    public init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        self.init(id: CGDirectDisplayID(number.uint32Value), frame: screen.frame, scale: screen.backingScaleFactor)
    }

    /// Every connected screen; the primary screen comes first.
    public static func current() -> [ScreenInfo] {
        return NSScreen.screens.compactMap(ScreenInfo.init(screen:))
    }
}
