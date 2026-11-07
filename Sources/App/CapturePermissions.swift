import AVFoundation
import Cocoa
import CoreGraphics
import ScreenCaptureKit

/// Screen Recording permission (TCC `ScreenCapture`) and Microphone permission (TCC `Microphone`).
/// Screen Recording has no Info.plist key, and a new grant only takes effect after the app relaunches.
/// The microphone needs `NSMicrophoneUsageDescription` (written by build.sh) and works right after a grant.
public enum CapturePermissions {
    public static let screenRecordingSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    public static let microphoneSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    public static var hasScreenAccess: Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Returns true when capture can start now. Otherwise asks macOS for access (the system prompt
    /// appears only the first time) and explains that a grant needs a relaunch.
    public static func ensureScreenAccess() -> Bool {
        if hasScreenAccess {
            return true
        }
        if CGRequestScreenCaptureAccess() {
            return true
        }
        presentScreenAccessAlert()
        return false
    }

    public static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(screenRecordingSettingsURL)
    }

    /// True for the ScreenCaptureKit error raised when Screen Recording is denied or was revoked.
    public static func isScreenAccessError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userDeclined.rawValue
    }

    /// Explains how to grant Screen Recording and that a relaunch is needed; offers the Settings pane.
    public static func presentScreenAccessAlert() {
        let settings = AlertPresenter.settingsAppName
        let response = AlertPresenter.run(
            message: "Screen Recording permission is required",
            informativeText: "Grant Screen Recording in \(AlertPresenter.privacySettingsPath), then relaunch \(AppConfig.appName).",
            buttons: ["Open \(settings)", "Cancel"]
        )
        if response == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    // MARK: - Microphone

    public static var hasMicrophoneAccess: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Calls `completion` with whether the mic may be used. Synchronous when the answer is already
    /// known; otherwise shows the system prompt (first time only) and completes on the main queue.
    public static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// Explains that the mic is off because access was denied, and offers the Settings pane.
    public static func presentMicrophoneAccessAlert() {
        let settings = AlertPresenter.settingsAppName
        let response = AlertPresenter.run(
            message: "Microphone access is required",
            informativeText: "To record your microphone, allow \(AppConfig.appName) in \(AlertPresenter.privacySettingsPath) › Microphone. Recording continues without the microphone.",
            buttons: ["Open \(settings)", "Cancel"]
        )
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(microphoneSettingsURL)
        }
    }
}
