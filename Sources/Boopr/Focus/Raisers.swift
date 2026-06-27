import AppKit

/// Rung 3 (non-multiplexer): activate the terminal app and AX-raise the window
/// whose title matches. This is the pre-refactor `SessionFocuser` fallback,
/// behavior-for-behavior (activate, then a 0.1s-delayed title raise so the
/// app/Space switch lands first).
struct TitleAXRaiser: WindowRaiser {
    let rung = 3
    func canHandle(_ ctx: RaiseContext) -> Bool { ctx.app != nil && ctx.titleHint != nil }
    func raise(_ ctx: RaiseContext) -> Bool {
        guard let app = ctx.app, let title = ctx.titleHint else { return false }
        RaiseSupport.activate(app)
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            RaiseSupport.raiseWindowByTitle(pid: pid, titleSubstring: title)
        }
        return true
    }
}

/// Rung 5: app-activation floor. Reached when we know the app but have no window
/// title to disambiguate — macOS still switches Space on activate().
struct AppActivationRaiser: WindowRaiser {
    let rung = 5
    func canHandle(_ ctx: RaiseContext) -> Bool { ctx.app != nil }
    func raise(_ ctx: RaiseContext) -> Bool {
        guard let app = ctx.app else { return false }
        RaiseSupport.activate(app)
        return true
    }
}
