import SwiftUI

@main
struct PiTalkiOSApp: App {
    @StateObject private var store = AppStore()
    @AppStorage("pitalk.appearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        // pitalk://session/<sessionKey>
        guard url.scheme == "pitalk", url.host == "session" else { return }
        let sessionKey = url.pathComponents.dropFirst().joined(separator: "/")
        guard !sessionKey.isEmpty else { return }
        store.deepLinkSessionId = sessionKey
        store.selectedSessionId = sessionKey
    }
}

/// User-selectable appearance mode.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            SessionsView()
                .tabItem {
                    Label("Sessions", systemImage: "waveform")
                }

            HistoryListView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            RemoteSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .tint(.blue)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onAppear {
            if let profile = store.activeProfile {
                store.connectToProfile(profile)
            }
        }
    }
}
