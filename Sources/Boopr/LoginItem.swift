import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the "Launch at Login" toggle.
///
/// `SMAppService.mainApp` requires the running binary to be inside an .app
/// bundle in /Applications (or ~/Applications). When invoked from a dev build
/// out of `.build/release/`, register() throws — we surface that as `false` so
/// the menu doesn't lie about state.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Flip the current state. Returns the new effective state.
    @discardableResult
    static func toggle() -> Bool {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
        }
        return svc.status == .enabled
    }
}
