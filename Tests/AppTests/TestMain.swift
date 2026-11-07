import Cocoa

@main
struct TestMain {
    static func main() {
        // Initialize NSApplication for AppKit UI components
        _ = NSApplication.shared

        print("==================================================")
        print("         Running Swift Native Test Suite          ")
        print("==================================================")

        var passed = 0
        var failed = 0
        let totalStart = CFAbsoluteTimeGetCurrent()

        let runTest: (String, () throws -> Void) -> Void = { name, block in
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try block()
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                print(String(format: "  ✔ PASS: %@ (%.2fms)", name, elapsedMs))
                passed += 1
            } catch {
                print("  ❌ FAIL: \(name) - \(error)")
                failed += 1
            }
        }

        print("\n--- Application Configuration & State Suite ---")
        AppTests.run(testRunner: runTest)

        print("\n--- Screen Recording Suite ---")
        RecordingTests.run(testRunner: runTest)

        print("\n--- Screen Geometry Suite ---")
        ScreenGeometryTests.run(testRunner: runTest)

        print("\n--- Audio Mixer Suite ---")
        AudioMixerTests.run(testRunner: runTest)

        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000.0

        print("\n--------------------------------------------------")
        print(String(format: "  Summary: %d Passed | %d Failed (Total: %.2fms)", passed, failed, totalElapsedMs))
        print("==================================================")

        if failed > 0 {
            exit(1)
        }
    }
}
