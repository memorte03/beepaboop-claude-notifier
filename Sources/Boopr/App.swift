import SwiftUI
import AppKit
import ServiceManagement

/// Entry point. Intercepts the hook/uninstall CLI invocations before any AppKit
/// init so `Boopr __hook …` runs as a plain command (no menu-bar app, no dock
/// icon) and exits; everything else launches the normal GUI.
@main
struct BooprMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 2 {
            switch args[1] {
            case "__hook":   HookCLI.run(Array(args.dropFirst(2)))   // exits
            case "__unwire": Bootstrap.unwireSettings(); exit(0)
            default:         break
            }
        }
        BooprApp.main()
    }
}

struct BooprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: appDelegate.store, port: appDelegate.port)
        } label: {
            Image(nsImage: MenuBarIcon.template)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(store: appDelegate.store, icons: appDelegate.iconRules)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NotificationStore()
    let iconRules = IconRuleStore()
    /// Same env var the hook scripts honor, so changing the port is one export.
    let port: UInt16 = ProcessInfo.processInfo.environment["BOOPR_PORT"]
        .flatMap(UInt16.init) ?? 7891
    private var server: HTTPServer?
    private var overlay: OverlayWindow?
    private var hostingView: NSHostingView<OverlayView>?
    private var pillBar: PillBarWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let view = OverlayView(
            store: store,
            icons: iconRules,
            onJump: { [weak self] req in
                SessionFocuser.focus(req: req)
                // Unblock a waiting /permission hook (decision "ask") so Claude
                // isn't held until the timeout — the user is handling it in the
                // terminal we just raised. Non-permission kinds just dismiss.
                self?.store.jumpResolve(id: req.id)
            },
            onResolve: { [weak self] req, decision in
                self?.store.resolve(id: req.id, decision: decision)
            },
            onAlwaysAllow: { [weak self] req in
                self?.store.alwaysAllow(req: req)
                self?.store.resolve(id: req.id, decision: "allow")
            },
            onDismiss: { [weak self] req in
                self?.store.dismiss(id: req.id)
            },
            onContentSizeChange: { [weak self] size in
                self?.overlay?.updateContentHeight(size.height)
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: OverlayWindow.panelSize)
        self.hostingView = hosting

        let panel = OverlayWindow(rootView: hosting)
        self.overlay = panel

        // Pre-warm so the first SwiftUI transition isn't dropped by layer init.
        DispatchQueue.main.async { panel.prewarm() }

        // Pill bar: missed notifications, one pill per session.
        let pillView = PillBarView(store: store, icons: iconRules) { [weak self] size in
            self?.pillBar?.updateContentSize(size)
            self?.syncPillBar()
        }
        let pillHosting = NSHostingView(rootView: pillView)
        self.pillBar = PillBarWindow(rootView: pillHosting)
        store.onPendingChange = { [weak self] in self?.syncPillBar() }
        store.startPendingWatcher()

        store.onChange = { [weak self] in
            guard let self, let panel = self.overlay else { return }
            if self.store.current != nil {
                panel.ignoresMouseEvents = false
                panel.show()
            } else {
                // Keep the panel on-screen during the SwiftUI removal transition,
                // then hide it once the animation completes.
                panel.ignoresMouseEvents = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    if self?.store.current == nil { panel.orderOut(nil) }
                }
            }
        }

        do {
            let server = try HTTPServer(port: port, store: store, token: AuthToken.load())
            server.start()
            self.server = server
            NSLog("boopr listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("server failed: \(error)")
            store.serverError = "Server failed on port \(port) — already running elsewhere?"
        }

        // Prompt for Accessibility once at launch so jump-to-session works.
        SessionFocuser.ensureAccessibilityPermission()
        store.refreshPermissions()

        // First-launch setup: install hooks + wire settings.json so a plain
        // drag-to-Applications install works with no terminal step.
        Bootstrap.runIfNeeded()
    }

    /// Shows/hides the pill bar and keeps the overlay card below it.
    private func syncPillBar() {
        guard let bar = pillBar else { return }
        if store.pending.isEmpty {
            bar.hide()
            overlay?.topOffset = 0
        } else {
            bar.show()
            // Keep a small, fixed gap between the pill bar's VISIBLE bottom and
            // the card's visible top. `bar.frame.height` includes the pill view's
            // transparent bottom shadow inset, which isn't part of the visible
            // bar — subtract it. The −22 folds the fixed offsets (pill top margin
            // 10 − card .top padding 16 − overlay margin 16) so the *visible* gap
            // lands at `pillToCardGap` no matter how much shadow room we reserve.
            let pillToCardGap: CGFloat = 18
            overlay?.topOffset = bar.frame.height - PillBarView.padBottom + pillToCardGap - 22
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: NotificationStore
    let port: UInt16
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Boopr")
            .font(.headline)
        Divider()
        if let err = store.serverError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
        } else {
            Text("Listening on 127.0.0.1:\(String(port))")
        }
        if let cur = store.current {
            Text("Active: \(cur.title)").lineLimit(1)
        }
        if !store.queue.isEmpty {
            Text("Queued: \(store.queue.count)")
        }
        Divider()
        permissionsSection
        Divider()
        notificationsSection
        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button(store.launchAtLogin ? "Launch at Login ✓" : "Launch at Login") {
            store.toggleLaunchAtLogin()
        }
        Divider()
        Menu("Debug") {
            Button("Test: Stop (done)")          { DebugFixtures.fire(.stop, store: store) }
            Button("Test: Notification (idle)")  { DebugFixtures.fire(.idle, store: store) }
            Button("Test: Permission (Bash)")    { DebugFixtures.fire(.permission, store: store) }
            Button("Test: Error")                { DebugFixtures.fire(.error, store: store) }
            Button("Test: Info")                 { DebugFixtures.fire(.info, store: store) }
            Divider()
            Button("Test: Queue 3 notifications") {
                DebugFixtures.fire(.stop, store: store)
                DebugFixtures.fire(.idle, store: store)
                DebugFixtures.fire(.permission, store: store)
            }
            Button("Dismiss current") {
                if let id = store.current?.id { store.dismiss(id: id) }
            }
            Divider()
            Button("Reinstall hooks") { Bootstrap.repair() }
                .help("Re-copy the hook scripts and re-wire ~/.claude/settings.json")
            Divider()
            Button("Preview all chimes") {
                Task { @MainActor in
                    for k: NotifyKind in [.stop, .idle, .permission, .info, .error] {
                        store.chime.play(for: k)
                        try? await Task.sleep(nanoseconds: 700_000_000)
                    }
                }
            }
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// TCC status with shortcuts into System Settings. Reads cached values and
    /// kicks an async refresh on open (the automation check is an Apple Event,
    /// kept off the synchronous menu-paint path).
    @ViewBuilder
    private var permissionsSection: some View {
        let ax = store.axStatus
        let auto = store.automationStatus
        Menu("Permissions") {
            Button {
                PermissionsStatus.openAccessibilitySettings()
            } label: {
                Label("Accessibility: \(ax.label)", systemImage: ax.symbol)
            }
            Button {
                PermissionsStatus.openAutomationSettings()
            } label: {
                Label("Automation (Ghostty): \(auto.label)", systemImage: auto.symbol)
            }
            Divider()
            Text("Both are needed for Jump to session.")
        }
        .onAppear { store.refreshPermissions() }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Menu("Notifications") {
            Toggle("Done (Stop)", isOn: store.bindingForKind(.stop))
            Toggle("Waiting for input", isOn: store.bindingForKind(.idle))
            Toggle("Permission prompts", isOn: store.bindingForKind(.permission))
            Toggle("Errors", isOn: store.bindingForKind(.error))
            Toggle("Info", isOn: store.bindingForKind(.info))
            Divider()
            Button(store.chime.muted ? "Unmute chimes" : "Mute chimes") {
                store.chime.muted.toggle()
            }
        }
    }
}

@MainActor
enum DebugFixtures {
    static func fire(_ kind: NotifyKind, store: NotificationStore) {
        let id = UUID().uuidString
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        switch kind {
        case .stop:
            store.enqueue(NotifyRequest(
                id: id, kind: .stop,
                repoName: "boopr", branch: "main",
                cwd: NSHomeDirectory() + "/Workspace/boopr",
                sessionId: "debug", title: "Claude is done",
                context: "Refactored auth flow, all tests passing.",
                terminalPid: pid, terminalApp: "com.apple.Terminal", windowTitle: "claude"
            ))
        case .idle:
            store.enqueue(NotifyRequest(
                id: id, kind: .idle,
                repoName: "boopr", branch: "feat/overlay",
                cwd: nil, sessionId: "debug",
                title: "Claude is waiting for you",
                context: "Pick one: a) split this PR, b) keep bundled, c) revert.",
                terminalPid: pid
            ))
        case .permission:
            // Use the same path the HTTP /permission route uses so we can also
            // exercise the Approve/Deny resolve flow.
            let req = NotifyRequest(
                id: id, kind: .permission,
                repoName: "boopr", branch: "main",
                cwd: NSHomeDirectory() + "/Workspace/boopr",
                sessionId: "debug",
                title: "Run shell command?",
                context: "$ rm -rf node_modules && npm install",
                toolName: "Bash",
                actions: ["Approve", "Deny"],
                terminalPid: pid, terminalApp: "com.apple.Terminal", windowTitle: "claude"
            )
            _ = store.enqueuePermission(req)
        case .error:
            store.enqueue(NotifyRequest(
                id: id, kind: .error,
                repoName: "boopr", branch: "main",
                title: "Tool failed",
                context: "Bash exited 1: command not found: foo",
                terminalPid: pid
            ))
        case .info:
            store.enqueue(NotifyRequest(id: id, kind: .info, title: "Info", context: "Debug info ping"))
        }
    }
}
