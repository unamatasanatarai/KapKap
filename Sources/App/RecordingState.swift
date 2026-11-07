import Foundation

/// Lifecycle of a screen recording. Transitions are pure so they can be unit tested.
///
///     idle --recordRequested--> configuring --recordConfirmed--> starting --didStart--> recording
///     recording --stopRequested--> finishing --didFinish--> idle
///     configuring --cancel--> idle
///     configuring --sectionChosen--> selecting --fullscreenChosen--> configuring
///     selecting --recordConfirmed--> starting
///     selecting --cancel--> idle
///     starting --startFailed--> idle
///     starting --startFailedRetryable--> configuring   (e.g. the display went away; the panel reappears)
///     recording --failed--> finishing                  (capture or writing failed; salvage what was recorded)
public enum RecordingState: Equatable {
    case idle
    /// The record control panel is showing.
    case configuring
    /// The panel is showing in Section mode, with the region overlay over every screen.
    case selecting
    case starting
    case recording
    case finishing

    /// Returns the state after `event`, or nil when the event is not valid in this state and must be ignored.
    public func next(_ event: RecordingEvent) -> RecordingState? {
        switch (self, event) {
        case (.idle, .recordRequested):
            return .configuring
        case (.configuring, .recordConfirmed):
            return .starting
        case (.configuring, .cancel):
            return .idle
        case (.configuring, .sectionChosen):
            return .selecting
        case (.selecting, .fullscreenChosen):
            return .configuring
        case (.selecting, .recordConfirmed):
            return .starting
        case (.selecting, .cancel):
            return .idle
        case (.starting, .didStart):
            return .recording
        case (.starting, .startFailed):
            return .idle
        case (.starting, .startFailedRetryable):
            return .configuring
        case (.recording, .stopRequested), (.recording, .failed):
            return .finishing
        case (.finishing, .didFinish):
            return .idle
        default:
            return nil
        }
    }
}

public enum RecordingEvent: CaseIterable {
    case recordRequested
    case recordConfirmed
    case cancel
    case sectionChosen
    case fullscreenChosen
    case didStart
    case startFailed
    /// Start failed in a way the user can fix from the panel, such as choosing another display.
    case startFailedRetryable
    case stopRequested
    /// Capture or writing failed mid-recording.
    case failed
    case didFinish
}
