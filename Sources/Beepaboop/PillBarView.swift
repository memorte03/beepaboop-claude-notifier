import SwiftUI

/// Horizontal bar of compact pills, one per Claude session with a missed
/// action. Click a pill → jump to its terminal; ✕ → drop it. Pills also
/// vanish on their own when the user visits the pane or the session sends a
/// newer event (NotificationStore owns that logic).
struct PillBarView: View {
    @ObservedObject var store: NotificationStore
    @ObservedObject var icons: IconRuleStore
    var onContentSizeChange: (CGSize) -> Void = { _ in }

    private let maxVisible = 5

    var body: some View {
        HStack(spacing: 8) {
            ForEach(store.pending.prefix(maxVisible)) { action in
                Pill(action: action,
                     projectIcon: icons.icon(forCwd: action.req.cwd),
                     onJump: { store.jumpPending(key: action.key) },
                     onClose: { store.clearPending(key: action.key) })
            }
            if store.pending.count > maxVisible {
                Text("+\(store.pending.count - maxVisible)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.10)))
            }
        }
        .padding(8)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ContentSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ContentSizeKey.self, perform: onContentSizeChange)
        // Animate on a cheap identity hash, not a freshly-allocated [String].
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: pendingIdentity)
    }

    /// Order-sensitive identity of the pending list, without allocating an array
    /// of keys on every body evaluation.
    private var pendingIdentity: Int {
        var hasher = Hasher()
        for action in store.pending { hasher.combine(action.key) }
        return hasher.finalize()
    }
}

private struct Pill: View {
    let action: PendingAction
    let projectIcon: NSImage?
    var onJump: () -> Void
    var onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            // The whole pill (except ✕) is one real Button — tap gestures can
            // miss the first click in a non-activating panel; buttons don't.
            Button(action: onJump) {
                HStack(spacing: 7) {
                    if let projectIcon {
                        Image(nsImage: projectIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: action.req.kind.symbolName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(action.req.kind.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text(action.req.repoName ?? action.req.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                            if projectIcon != nil {
                                Image(systemName: action.req.kind.symbolName)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(action.req.kind.accentColor)
                            }
                        }
                        HStack(spacing: 4) {
                            if let branch = action.req.branch {
                                // Truncate the string, not the layout —
                                // .frame(maxWidth:) makes the text expand TO
                                // the cap, giving short names a fat pill.
                                Text(branch.middleTruncated(to: 26))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                            // Relative age, refreshed once a minute.
                            TimelineView(.periodic(from: action.since, by: 60)) { ctx in
                                Text(age(at: ctx.date))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to session")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.55))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(hovering ? 0.18 : 0.10)))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
        .background(
            ZStack {
                BlurView(material: .hudWindow, blendingMode: .behindWindow)
                Color(red: 0.06, green: 0.06, blue: 0.07,
                      opacity: hovering ? 0.45 : 0.60)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(hovering ? 0.22 : 0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)
        )
        .onHover { hovering = $0 }
    }

    private func age(at date: Date) -> String {
        let mins = max(0, Int(date.timeIntervalSince(action.since) / 60))
        if mins < 1 { return "now" }
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h"
    }
}

extension String {
    /// "feature/very-long-branch-name-HYP-1234" → "feature/very…HYP-1234"
    func middleTruncated(to max: Int) -> String {
        guard count > max, max > 3 else { return self }
        let keep = (max - 1) / 2
        return "\(prefix(keep))…\(suffix(keep))"
    }
}
