import Foundation

/// Trace logging gated on the `BEEPABOOP_DEBUG` env var, so a public
/// build's Console isn't noisy. Errors should still use `NSLog` directly.
enum Debug {
    static let enabled = ProcessInfo.processInfo.environment["BEEPABOOP_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        if enabled { NSLog("%@", message()) }
    }
}
