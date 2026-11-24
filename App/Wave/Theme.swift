import SwiftUI
import WaveCore

/// One colour per gesture, used in the menu, the on-screen confirmation and Settings.
extension GestureEvent.Kind {
    var tint: Color {
        switch self {
        case .push: return .blue
        case .pull: return .indigo
        case .swipeLeft, .swipeRight: return .teal
        case .grab: return .orange
        }
    }
}

extension DialTarget {
    var tint: Color { self == .volume ? .pink : .yellow }
}

/// A gesture's symbol on a tinted rounded square.
struct GestureBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}
