import SwiftUI

/// Single source of truth for how each notification kind is presented (glyph,
/// accent color, short state word). Shared by the overlay card, the pill bar,
/// and any other surface, so a palette/icon change happens in one place.
extension NotifyKind {
    var symbolName: String {
        switch self {
        case .stop:       return "checkmark.circle.fill"
        case .idle:       return "ellipsis.bubble.fill"
        case .permission: return "bolt.fill"
        case .info:       return "info.circle.fill"
        case .error:      return "exclamationmark.triangle.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .stop:       return Color(red: 0.62, green: 0.92, blue: 0.55)
        case .idle:       return Color(red: 1.0, green: 0.84, blue: 0.36)
        case .permission: return Color(red: 1.0, green: 0.62, blue: 0.30)
        case .info:       return Color(red: 0.45, green: 0.78, blue: 1.0)
        case .error:      return Color(red: 1.0, green: 0.40, blue: 0.42)
        }
    }

    var stateText: String {
        switch self {
        case .stop:       return "done"
        case .idle:       return "needs input"
        case .permission: return "permission"
        case .info:       return "info"
        case .error:      return "error"
        }
    }
}
