import SwiftUI

@main
struct NixOSControlApp: App {
    @StateObject private var app = AppState()

    init() {
        Theme.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
