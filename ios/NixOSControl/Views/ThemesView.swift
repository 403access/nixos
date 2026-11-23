import SwiftUI

private struct ThemeSelection: Identifiable {
    enum Kind {
        case profile
        case gtk
        case wallpaper
    }

    let id: String
    let name: String
    let kind: Kind
}

struct ThemesView: View {
    @EnvironmentObject private var app: AppState
    @State private var pending: ThemeSelection?
    @State private var actionError: String?
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = app.lastError, app.themes == nil {
                    ErrorBanner(message: error)
                }

                if notice != nil {
                    Text(notice ?? "")
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Theme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }

                if let catalog = app.themes {
                    currentCard(catalog)

                    profileSection(catalog)
                    gtkSection(catalog)
                    wallpaperSection(catalog)

                    if let job = app.activeJob {
                        jobCard(job)
                    }

                    Text("Applying a theme writes desktop/selected.nix and runs nixos-rebuild switch. The previous generation stays available for rollback.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if app.isLoadingThemes {
                    ProgressView("Loading themes…")
                        .padding(.top, 40)
                } else {
                    ContentUnavailableView(
                        "No themes available",
                        systemImage: "paintpalette",
                        description: Text("Check the connection and refresh.")
                    )
                    .padding(.top, 24)
                }
            }
            .padding(16)
        }
        .appBackground()
        .navigationTitle("Themes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await app.loadThemes() }
                } label: {
                    if app.isLoadingThemes {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(app.isLoadingThemes)
            }
        }
        .refreshable {
            await app.loadThemes()
        }
        .task {
            if app.themes == nil {
                await app.loadThemes()
            }
        }
        .alert(
            "Apply theme?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { selection in
            Button("Apply") {
                Task { await apply(selection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { selection in
            Text("Apply \(selection.name) and run nixos-rebuild switch? The desktop will be rebuilt and may restart.")
        }
        .alert(
            "Theme change failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private func currentCard(_ catalog: ThemeCatalog) -> some View {
        Card("Current theme", systemImage: "paintpalette") {
            InfoRow(label: "Desktop", value: catalog.current.profile)
            InfoRow(label: "GTK theme", value: catalog.current.gtkTheme)
            InfoRow(label: "Wallpaper", value: catalog.current.wallpaper)
            InfoRow(label: "Catppuccin flavour", value: catalog.current.flavour)
            InfoRow(label: "Accent", value: catalog.current.accent)
        }
    }

    private func profileSection(_ catalog: ThemeCatalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Desktop profiles")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Switching profiles changes the desktop session, login manager and dotfiles.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            ForEach(catalog.profiles) { theme in
                ThemeCardView(theme: theme, busy: app.activeJob?.isRunning == true) {
                    pending = ThemeSelection(id: theme.id, name: theme.name, kind: .profile)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gtkSection(_ catalog: ThemeCatalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GTK theme")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("The GTK, icon and cursor theme is independent of the desktop profile.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            ForEach(catalog.gtkThemes) { theme in
                ThemeCardView(theme: theme, busy: app.activeJob?.isRunning == true) {
                    pending = ThemeSelection(id: theme.id, name: theme.name, kind: .gtk)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wallpaperSection(_ catalog: ThemeCatalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wallpaper")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("The wallpaper follows the GTK theme by default. Choose one here to pin it for the desktop and login screen.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            ForEach(catalog.wallpapers) { theme in
                ThemeCardView(theme: theme, busy: app.activeJob?.isRunning == true) {
                    pending = ThemeSelection(id: theme.id, name: theme.name, kind: .wallpaper)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func jobCard(_ job: Job) -> some View {
        Card("Theme rebuild", systemImage: "hammer") {
            HStack {
                StatusBadge(text: job.status.capitalized, tint: .jobStatus(job.status))
                Spacer()
                Text(job.kind)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }

            if job.isRunning {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !job.output.isEmpty {
                ScrollView {
                    Text(job.output)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(
                    Theme.sunken,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }

            if let error = job.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private func apply(_ selection: ThemeSelection) async {
        actionError = nil
        notice = nil
        let error = await app.applyTheme(
            profile: selection.kind == .profile ? selection.id : nil,
            gtkTheme: selection.kind == .gtk ? selection.id : nil,
            wallpaper: selection.kind == .wallpaper ? selection.id : nil
        )
        if let error {
            actionError = error
        } else {
            notice = "\(selection.name) selected. Rebuilding the host…"
        }
    }
}

private struct ThemeCardView: View {
    let theme: ThemeCard
    let busy: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let screenshot = theme.screenshot {
                Image(screenshot)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [accent, Theme.background],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Text(theme.name)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
                }
                .frame(height: 170)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(theme.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    if theme.current {
                        StatusBadge(text: "current", tint: Theme.success)
                    }
                }

                Text(theme.description)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 3) {
                    ForEach(theme.details, id: \.self) { detail in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .foregroundStyle(accent)
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }

                Button(action: onApply) {
                    Text(theme.current ? "Active" : "Apply theme")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(theme.current ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                .disabled(theme.current || busy)
                .opacity(theme.current ? 0.6 : 1)
            }
            .padding(14)
        }
        .background(
            Theme.cardGradient,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    theme.current ? Theme.success.opacity(0.5) : Theme.border,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private var accent: Color {
        let text = theme.accent.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt32(text, radix: 16) else {
            return Theme.accent
        }
        return Color(hex: value)
    }
}

/// Type-erased button style so the active and inactive states can share a
/// single modifier chain.
private struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}