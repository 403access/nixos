import SwiftUI
import UIKit

/// The app palette. It mirrors the marketing site so the iPhone app and the
/// website feel like the same product: a deep navy background, soft blue
/// surfaces, a blue-to-teal brand gradient and cool secondary text.
enum Theme {
    // Surfaces
    static let background = Color(hex: 0x080B14)
    static let surface = Color(hex: 0x0D1424)
    static let raised = Color(hex: 0x111A2E)
    static let sunken = Color(hex: 0x060A12)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.13)

    // Brand
    static let accent = Color(hex: 0x5B8CFF)
    static let accentLight = Color(hex: 0x7AA2FF)
    static let teal = Color(hex: 0x4FD1C5)
    static let onAccent = Color(hex: 0x06101F)

    // Text
    static let textPrimary = Color(hex: 0xF4F7FF)
    static let textSecondary = Color(hex: 0x93A4C3)
    static let textMuted = Color(hex: 0x6F81A3)

    // Status
    static let success = Color(hex: 0x4ADE80)
    static let warning = Color(hex: 0xF5A623)
    static let danger = Color(hex: 0xFF6B6B)
    static let purple = Color(hex: 0xC084FC)

    static let brandGradient = LinearGradient(
        colors: [accent, teal],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        colors: [raised.opacity(0.72), Color(hex: 0x090E19).opacity(0.92)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let backgroundGlow = RadialGradient(
        colors: [accent.opacity(0.16), teal.opacity(0.06), .clear],
        center: .topTrailing,
        startRadius: 0,
        endRadius: 540
    )

    /// Applies the dark appearance to UIKit-backed pieces such as navigation
    /// bars and the tab bar. SwiftUI is additionally forced to dark mode at
    /// the app root.
    static func configureAppearance() {
        let navigationBar = UINavigationBarAppearance()
        navigationBar.configureWithOpaqueBackground()
        navigationBar.backgroundColor = UIColor(background)
        navigationBar.shadowColor = UIColor.white.withAlphaComponent(0.07)
        navigationBar.titleTextAttributes = [.foregroundColor: UIColor(textPrimary)]
        navigationBar.largeTitleTextAttributes = [.foregroundColor: UIColor(textPrimary)]

        UINavigationBar.appearance().standardAppearance = navigationBar
        UINavigationBar.appearance().compactAppearance = navigationBar
        UINavigationBar.appearance().scrollEdgeAppearance = navigationBar
        UINavigationBar.appearance().tintColor = UIColor(accent)

        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        tabBar.backgroundColor = UIColor(surface)
        tabBar.shadowColor = UIColor.white.withAlphaComponent(0.07)

        for item in [
            tabBar.stackedLayoutAppearance,
            tabBar.inlineLayoutAppearance,
            tabBar.compactInlineLayoutAppearance,
        ] {
            item.normal.iconColor = UIColor(textMuted)
            item.normal.titleTextAttributes = [.foregroundColor: UIColor(textMuted)]
            item.selected.iconColor = UIColor(accent)
            item.selected.titleTextAttributes = [.foregroundColor: UIColor(accent)]
        }

        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar
        UITabBar.appearance().tintColor = UIColor(accent)
    }
}

/// Full-screen backdrop with the same soft blue glow used behind the hero on
/// the marketing site.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            Theme.backgroundGlow
        }
        .ignoresSafeArea()
    }
}

extension View {
    func appBackground() -> some View {
        background(AppBackground())
    }
}

/// Blue-to-teal gradient button used for the primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption.weight(.semibold) : .headline)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 6 : 12)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(
                Theme.brandGradient,
                in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous)
            )
            .shadow(
                color: Theme.teal.opacity(isEnabled ? 0.22 : 0),
                radius: 14,
                y: 6
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

/// Quiet, bordered action that sits next to a primary button.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                Theme.raised.opacity(configuration.isPressed ? 0.9 : 0.5),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.borderStrong, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
