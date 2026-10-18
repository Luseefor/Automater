import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppAccent: String, CaseIterable, Identifiable {
    case blue, indigo, teal, green, orange, rose
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.14, green: 0.40, blue: 0.93)
        case .indigo: return Color(red: 0.40, green: 0.33, blue: 0.88)
        case .teal: return Color(red: 0.00, green: 0.53, blue: 0.55)
        case .green: return Color(red: 0.17, green: 0.55, blue: 0.34)
        case .orange: return Color(red: 0.85, green: 0.39, blue: 0.12)
        case .rose: return Color(red: 0.78, green: 0.25, blue: 0.44)
        }
    }
}

struct AppAppearance: ViewModifier {
    @AppStorage("appearance.theme") private var theme: AppTheme = .light
    @AppStorage("appearance.accent") private var accent: AppAccent = .blue

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.colorScheme)
            .tint(accent.color)
            .accentColor(accent.color)
    }
}

/// Neutral, consistently sized controls for the header; no toolbar bubbles.
struct HeaderIcon: View {
    let name: String
    var selected = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.65))
            .frame(width: 30, height: 30)
            .background(selected ? Color.accentColor.opacity(0.12)
                        : Color.primary.opacity(hovering ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct AppBrandLabel: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: AutomaterBrand.icon(side: 40))
                .resizable().frame(width: 22, height: 22)
            Text("Tandem").font(.system(size: 13, weight: .semibold))
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}
