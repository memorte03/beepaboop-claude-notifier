import SwiftUI

struct ContentSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct OverlayView: View {
    @ObservedObject var store: NotificationStore
    @ObservedObject var icons: IconRuleStore
    var onJump: (NotifyRequest) -> Void
    var onResolve: (NotifyRequest, String) -> Void
    var onAlwaysAllow: (NotifyRequest) -> Void = { _ in }
    var onDismiss: (NotifyRequest) -> Void
    /// Called when the rendered content size changes — wired to the OverlayWindow
    /// so it can grow the panel to fit (e.g. when the diff expands on hover).
    var onContentSizeChange: (CGSize) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .top) {
            // Stable hit-test bedrock — minimum height so the panel never
            // collapses; grows naturally with the card.
            Color.clear
                .frame(width: 520, height: 200)
                .allowsHitTesting(false)
            if let n = store.current {
                card(n)
                    .frame(width: 440)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    // Fresh identity per notification so transient view state
                    // (e.g. DiffView's expand flag) doesn't leak to the next one.
                    .id(n.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ContentSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ContentSizeKey.self, perform: onContentSizeChange)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: store.current?.id)
    }

    @ViewBuilder
    private func card(_ request: NotifyRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                chip(request)
                Spacer(minLength: 0)
                if !store.queue.isEmpty {
                    Text("+\(store.queue.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.10)))
                }
                CloseButton(timer: store.currentTimer) { onDismiss(request) }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(request.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let ctx = request.context, !ctx.isEmpty {
                    Text(ctx)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            if let diff = request.diffPreview, !diff.isEmpty {
                DiffView(text: diff)
            }

            HStack(spacing: 8) {
                if request.kind == .permission, let actions = request.actions, !actions.isEmpty {
                    ForEach(actions, id: \.self) { action in
                        Button(action) {
                            onResolve(request, mapDecision(action))
                        }
                        .buttonStyle(PillButtonStyle(prominent: isPrimary(action)))
                    }
                    if showsAlwaysButton(request) {
                        Button {
                            onAlwaysAllow(request)
                        } label: {
                            Label("Always", systemImage: "infinity")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .help("Always approve \(request.toolName ?? "this tool") for this Claude session")
                    }
                }
                Spacer(minLength: 0)
                if request.terminalPid != nil || request.windowTitle != nil
                    || request.tmuxPane != nil || request.terminalApp != nil {
                    Button {
                        onJump(request)
                    } label: {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(IconPillButtonStyle())
                    .help("Jump to session")
                }
            }
        }
        .padding(18)
        .background(
            ZStack {
                // Behind-window blur — picks up the wallpaper / apps underneath
                BlurView(material: .hudWindow, blendingMode: .behindWindow)
                // Subtle dark tint on top of the blur (Raycast-ish)
                Color(red: 0.06, green: 0.06, blue: 0.07, opacity: 0.55)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        )
    }

    /// Same two-line identity style as the pill bar: project icon, repo name
    /// with the kind glyph on top, branch underneath (long branch names
    /// middle-truncate instead of stretching the chip).
    private func chip(_ request: NotifyRequest) -> some View {
        let projectIcon = icons.icon(forCwd: request.cwd)
        return HStack(spacing: 7) {
            // User-configured project icon (Settings → Project Icons),
            // matched by regex against the session's cwd.
            if let projectIcon {
                Image(nsImage: projectIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: request.kind.symbolName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(request.kind.accentColor)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(request.repoName ?? request.kind.stateText)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if projectIcon != nil {
                        Image(systemName: request.kind.symbolName)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(request.kind.accentColor)
                    }
                }
                if let branch = request.branch {
                    Text(branch.middleTruncated(to: 32))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 11).padding(.vertical, 4)
        .background(
            Capsule().fill(.white.opacity(0.10))
        )
    }

    private func mapDecision(_ action: String) -> String {
        let a = action.lowercased()
        if a.contains("approve") || a == "allow" || a == "yes" { return "allow" }
        if a.contains("deny") || a.contains("reject") || a == "no" { return "deny" }
        return "ask"
    }

    private func isPrimary(_ action: String) -> Bool {
        let a = action.lowercased()
        return a.contains("approve") || a == "allow" || a == "yes"
    }

    private func showsAlwaysButton(_ n: NotifyRequest) -> Bool {
        // Only useful for tools that are uniformly safe-to-repeat once approved.
        // Bash deliberately excluded — different commands shouldn't share a blanket allow.
        guard n.sessionId != nil, let tool = n.toolName else { return false }
        return ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool)
    }
}

struct DiffView: View {
    /// Split once at init — not recomputed on every body evaluation (the
    /// countdown ring and hover animation re-render this subtree frequently).
    private let lines: [String]
    @State private var hasExpanded = false

    private let collapsedHeight: CGFloat = 110
    private let maxExpandedHeight: CGFloat = 800
    private let lineHeight: CGFloat = 16

    init(text: String) {
        self.lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var contentNeeded: CGFloat {
        let n = max(1, lines.count)
        return CGFloat(n) * lineHeight + 16
    }

    private var height: CGFloat {
        // Once hovered, the panel stays expanded for the life of this notification.
        // User can scroll freely without the panel chasing them.
        hasExpanded ? min(contentNeeded, maxExpandedHeight) : collapsedHeight
    }

    var body: some View {
        ThinScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(lines.indices, id: \.self) { i in
                    let line = lines[i]
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(bg(for: line))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(hasExpanded ? 0.12 : 0.06), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { h in if h { hasExpanded = true } }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasExpanded)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color(red: 0.65, green: 0.95, blue: 0.55)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color(red: 1.0, green: 0.55, blue: 0.55)
        }
        if line.hasPrefix("@@") {
            return Color(red: 0.7, green: 0.78, blue: 1.0)
        }
        return .white.opacity(0.55)
    }

    private func bg(for line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return Color.green.opacity(0.08)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return Color.red.opacity(0.08)
        }
        return .clear
    }
}

struct CloseButton: View {
    var timer: ProgressTimer?
    var action: () -> Void
    @State private var hovering = false

    // Integer values everywhere — half-pixels (1.5, 0.75, 5.5…) get rounded
    // asymmetrically on Retina, which is what produced the 1-px top/left bias.
    private let buttonSize: CGFloat = 22
    private let gap: CGFloat       = 4
    private let ringWidth: CGFloat = 2

    var body: some View {
        Group {
            if let t = timer {
                // ~15fps is plenty for a slow seconds-scale ring and halves the
                // redraw cost of the card subtree while an overlay is up.
                TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: false)) { ctx in
                    let elapsed = ctx.date.timeIntervalSince(t.start)
                    let remaining = max(0, 1 - elapsed / t.duration)
                    button(progress: remaining)
                }
            } else {
                button(progress: 1)
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func button(progress: Double) -> some View {
        Button(action: action) {
            Circle()
                .fill(.white.opacity(hovering ? 0.21 : 0.15))
                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .overlay(
                    XMark()
                        .stroke(.white.opacity(hovering ? 1.0 : 0.92),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: 8, height: 8)
                )
                .frame(width: buttonSize, height: buttonSize)
                .padding(gap + ringWidth)   // integer = 6 → no subpixel rounding
                .background(
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.28),
                                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(.white.opacity(0.65),
                                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(ringWidth / 2)   // integer = 1 → still safe
                )
        }
        .buttonStyle(.plain)
    }
}

/// Pixel-perfect X glyph — no SF Symbol bounding-box padding to worry about.
struct XMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

struct IconPillButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
            .frame(width: 32, height: 32)
            .background(
                Circle().fill(.white.opacity(hovering ? 0.16 : 0.10))
            )
            .overlay(
                Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(
                Capsule().fill(prominent
                    ? AnyShapeStyle(Color.white.opacity(hovering ? 0.95 : 1.0))
                    : AnyShapeStyle(Color.white.opacity(hovering ? 0.18 : 0.12)))
            )
            .overlay(
                Capsule().strokeBorder(
                    prominent ? .white.opacity(0) : .white.opacity(0.18),
                    lineWidth: 1
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}
