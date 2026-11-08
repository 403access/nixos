import SwiftUI

enum AppTab: Hashable {
    case dashboard
    case services
    case storage
    case system
    case settings
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @State private var selection: AppTab = {
        #if DEBUG
        if let tab = ProcessInfo.processInfo.environment["NIXOS_CONTROL_TAB"] {
            switch tab {
            case "services":
                return .services
            case "storage":
                return .storage
            case "system":
                return .system
            case "settings":
                return .settings
            default:
                break
            }
        }
        #endif
        return .dashboard
    }()

    var body: some View {
        Group {
            if app.isConfigured {
                TabView(selection: $selection) {
                    DashboardView(selection: $selection)
                        .tabItem { Label("Dashboard", systemImage: "gauge") }
                        .tag(AppTab.dashboard)

                    ServicesView()
                        .tabItem { Label("Services", systemImage: "gearshape.2") }
                        .tag(AppTab.services)

                    StorageView()
                        .tabItem { Label("Storage", systemImage: "internaldrive") }
                        .tag(AppTab.storage)

                    SystemView()
                        .tabItem { Label("System", systemImage: "server.rack") }
                        .tag(AppTab.system)

                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
                .task {
                    if app.status == nil {
                        await app.refreshStatus()
                    }
                }
            } else {
                SetupView()
            }
        }
    }
}
