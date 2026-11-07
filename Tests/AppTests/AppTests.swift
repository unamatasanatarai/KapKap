import Foundation

public enum AppTests {
    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("AppConfig returns valid non-empty application name") {
            assert(!AppConfig.appName.isEmpty, "App name should not be empty")
        }

        testRunner("AppConfig returns valid bundle identifier") {
            assert(!AppConfig.bundleIdentifier.isEmpty, "Bundle identifier should not be empty")
            assert(AppConfig.bundleIdentifier.contains("."), "Bundle identifier should be reverse-DNS style")
        }

        testRunner("AppConfig provides version string") {
            assert(!AppConfig.version.isEmpty, "Version should not be empty")
        }

        testRunner("AppConfig provides build number") {
            assert(!AppConfig.buildNumber.isEmpty, "Build number should not be empty")
        }

        testRunner("StatusBarController initializes menu correctly") {
            let controller = StatusBarController()
            assert(controller.currentMenu.items.count >= 2, "Menu should have items")
            assert(controller.currentMenu.items.contains { $0.title.contains("Quit") }, "Menu should contain quit item")
        }
    }
}
