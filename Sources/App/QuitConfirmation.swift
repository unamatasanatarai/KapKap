import Foundation

/// Double ⌘Q to quit: the first press arms a short window and asks for a second press; a second press
/// inside the window quits. Pure state with an injectable clock, so it is unit-testable.
public final class QuitConfirmation {
    public static let defaultWindow: TimeInterval = 2

    public let window: TimeInterval
    private var armedAt: Date?

    /// Called with true when the first press arms the prompt, false when it expires or is consumed.
    public var onPromptChanged: ((Bool) -> Void)?

    public init(window: TimeInterval = QuitConfirmation.defaultWindow) {
        self.window = window
    }

    public var isArmed: Bool {
        return armedAt != nil
    }

    /// Registers one ⌘Q press. Returns true when the app should quit now.
    @discardableResult
    public func press(at now: Date = Date()) -> Bool {
        if let armedAt = armedAt, now.timeIntervalSince(armedAt) <= window {
            reset()
            return true
        }
        armedAt = now
        onPromptChanged?(true)
        return false
    }

    /// Ends the prompt without quitting (the window elapsed).
    public func expire(at now: Date = Date()) {
        guard let armedAt = armedAt, now.timeIntervalSince(armedAt) >= window else { return }
        reset()
    }

    private func reset() {
        guard armedAt != nil else { return }
        armedAt = nil
        onPromptChanged?(false)
    }
}
